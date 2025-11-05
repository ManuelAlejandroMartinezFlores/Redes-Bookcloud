#!/bin/bash

################################################################################
# LDAP User Creation Script
# This script creates new LDAP users for SSH authentication
################################################################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# LDAP Configuration
LDAP_ADMIN_DN="cn=admin,dc=bookcloud,dc=com"
LDAP_BASE_DN="dc=bookcloud,dc=com"
LDAP_PEOPLE_OU="ou=people,dc=bookcloud,dc=com"

# Group GIDs
SALES_GID=5001
HR_GID=5002

# Starting UID (will auto-increment from highest existing)
NEXT_UID=10001

################################################################################
# Functions
################################################################################

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

check_ldap_connection() {
    if ! ldapsearch -x -b "$LDAP_BASE_DN" -s base >/dev/null 2>&1; then
        print_error "Cannot connect to LDAP server. Are you on the LDAP server?"
        exit 1
    fi
}

get_next_uid() {
    # Get the highest uidNumber currently in use
    local highest_uid=$(ldapsearch -x -LLL -b "$LDAP_PEOPLE_OU" "(objectClass=posixAccount)" uidNumber 2>/dev/null | grep "uidNumber:" | awk '{print $2}' | sort -n | tail -1)
    
    if [ -z "$highest_uid" ]; then
        echo $NEXT_UID
    else
        echo $((highest_uid + 1))
    fi
}

user_exists() {
    local username=$1
    ldapsearch -x -LLL -b "$LDAP_PEOPLE_OU" "(uid=$username)" dn 2>/dev/null | grep -q "^dn:"
}

create_user() {
    local username=$1
    local firstname=$2
    local lastname=$3
    local group=$4
    local email=$5
    
    # Determine GID based on group
    local gid
    case $group in
        sales)
            gid=$SALES_GID
            ;;
        hr)
            gid=$HR_GID
            ;;
        *)
            print_error "Invalid group. Must be 'sales' or 'hr'"
            return 1
            ;;
    esac
    
    # Check if user already exists
    if user_exists "$username"; then
        print_error "User '$username' already exists!"
        return 1
    fi
    
    # Get next available UID
    local uid=$(get_next_uid)
    
    # Create LDIF content
    local ldif_file="/tmp/${username}.ldif"
    cat > "$ldif_file" <<EOF
dn: uid=${username},${LDAP_PEOPLE_OU}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ${username}
cn: ${firstname} ${lastname}
sn: ${lastname}
givenName: ${firstname}
mail: ${email}
uidNumber: ${uid}
gidNumber: ${gid}
homeDirectory: /home/${username}
loginShell: /bin/bash
EOF
    
    print_status "Creating user '$username' with UID $uid in group '$group' (GID $gid)..."
    
    # Add user to LDAP
    if ldapadd -x -D "$LDAP_ADMIN_DN" -W -f "$ldif_file"; then
        print_status "✓ User '$username' created successfully!"
        rm "$ldif_file"
        
        # Set password
        print_status "Setting password for '$username'..."
        if ldappasswd -x -D "$LDAP_ADMIN_DN" -W -S "uid=${username},${LDAP_PEOPLE_OU}"; then
            print_status "✓ Password set successfully!"
        else
            print_error "Failed to set password"
            return 1
        fi
        
        # Display user info
        echo ""
        print_status "User Details:"
        echo "  Username: $username"
        echo "  Full Name: $firstname $lastname"
        echo "  Email: $email"
        echo "  UID: $uid"
        echo "  Group: $group (GID: $gid)"
        echo "  Home: /home/$username"
        echo ""
        
        return 0
    else
        print_error "Failed to create user"
        rm "$ldif_file"
        return 1
    fi
}

interactive_mode() {
    echo "========================================================================"
    echo "                    LDAP User Creation Wizard"
    echo "========================================================================"
    echo ""
    
    # Get username
    read -p "Enter username (e.g., salesuser3): " username
    if [ -z "$username" ]; then
        print_error "Username cannot be empty"
        exit 1
    fi
    
    # Get first name
    read -p "Enter first name: " firstname
    if [ -z "$firstname" ]; then
        print_error "First name cannot be empty"
        exit 1
    fi
    
    # Get last name
    read -p "Enter last name: " lastname
    if [ -z "$lastname" ]; then
        print_error "Last name cannot be empty"
        exit 1
    fi
    
    # Get group
    echo ""
    echo "Available groups:"
    echo "  1) sales"
    echo "  2) hr"
    read -p "Select group (1 or 2): " group_choice
    
    case $group_choice in
        1)
            group="sales"
            ;;
        2)
            group="hr"
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
    
    # Get email
    read -p "Enter email (default: ${username}@bookcloud.com): " email
    if [ -z "$email" ]; then
        email="${username}@bookcloud.com"
    fi
    
    echo ""
    echo "========================================================================"
    echo "Summary:"
    echo "  Username: $username"
    echo "  Name: $firstname $lastname"
    echo "  Email: $email"
    echo "  Group: $group"
    echo "========================================================================"
    echo ""
    
    read -p "Create this user? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "User creation cancelled"
        exit 0
    fi
    
    create_user "$username" "$firstname" "$lastname" "$group" "$email"
}

bulk_create() {
    local csv_file=$1
    
    if [ ! -f "$csv_file" ]; then
        print_error "File not found: $csv_file"
        exit 1
    fi
    
    print_status "Reading users from $csv_file..."
    echo ""
    
    local line_num=0
    while IFS=',' read -r username firstname lastname group email; do
        line_num=$((line_num + 1))
        
        # Skip header line
        if [ $line_num -eq 1 ]; then
            continue
        fi
        
        # Trim whitespace
        username=$(echo "$username" | xargs)
        firstname=$(echo "$firstname" | xargs)
        lastname=$(echo "$lastname" | xargs)
        group=$(echo "$group" | xargs)
        email=$(echo "$email" | xargs)
        
        # Set default email if empty
        if [ -z "$email" ]; then
            email="${username}@bookcloud.com"
        fi
        
        echo "========================================================================"
        print_status "Processing user $line_num: $username"
        echo "========================================================================"
        
        if create_user "$username" "$firstname" "$lastname" "$group" "$email"; then
            print_status "✓ Successfully created user: $username"
        else
            print_error "✗ Failed to create user: $username"
        fi
        
        echo ""
    done < "$csv_file"
    
    print_status "Bulk creation complete!"
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -i, --interactive       Interactive mode (default)"
    echo "  -u, --user USERNAME     Create single user (requires other options)"
    echo "  -f, --firstname NAME    First name"
    echo "  -l, --lastname NAME     Last name"
    echo "  -g, --group GROUP       Group (sales or hr)"
    echo "  -e, --email EMAIL       Email address"
    echo "  -b, --bulk FILE         Bulk create from CSV file"
    echo "  -h, --help              Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -i"
    echo "  $0 -u jdoe -f John -l Doe -g sales -e jdoe@bookcloud.com"
    echo "  $0 -b users.csv"
    echo ""
    echo "CSV Format for bulk creation:"
    echo "  username,firstname,lastname,group,email"
    echo "  salesuser3,John,Doe,sales,jdoe@bookcloud.com"
    echo "  hruser3,Jane,Smith,hr,jsmith@bookcloud.com"
    echo ""
}

################################################################################
# Main Script
################################################################################

# Check LDAP connection
check_ldap_connection

# Parse command line arguments
if [ $# -eq 0 ]; then
    interactive_mode
    exit 0
fi

# Parse options
MODE="interactive"
USERNAME=""
FIRSTNAME=""
LASTNAME=""
GROUP=""
EMAIL=""
CSV_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interactive)
            MODE="interactive"
            shift
            ;;
        -u|--user)
            USERNAME="$2"
            MODE="single"
            shift 2
            ;;
        -f|--firstname)
            FIRSTNAME="$2"
            shift 2
            ;;
        -l|--lastname)
            LASTNAME="$2"
            shift 2
            ;;
        -g|--group)
            GROUP="$2"
            shift 2
            ;;
        -e|--email)
            EMAIL="$2"
            shift 2
            ;;
        -b|--bulk)
            CSV_FILE="$2"
            MODE="bulk"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Execute based on mode
case $MODE in
    interactive)
        interactive_mode
        ;;
    single)
        if [ -z "$USERNAME" ] || [ -z "$FIRSTNAME" ] || [ -z "$LASTNAME" ] || [ -z "$GROUP" ]; then
            print_error "Missing required options for single user creation"
            show_usage
            exit 1
        fi
        
        if [ -z "$EMAIL" ]; then
            EMAIL="${USERNAME}@bookcloud.com"
        fi
        
        create_user "$USERNAME" "$FIRSTNAME" "$LASTNAME" "$GROUP" "$EMAIL"
        ;;
    bulk)
        bulk_create "$CSV_FILE"
        ;;
esac