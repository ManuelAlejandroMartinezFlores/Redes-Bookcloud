#!/bin/bash

################################################################################
# LDAP SSH Client Configuration Script (Using nslcd)
# This script configures a VM to authenticate SSH users via LDAP
# Only users in 'sales' and 'hr' groups will be allowed to login
################################################################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables - MODIFY THESE
LDAP_SERVER_IP="10.20.10.3"  # Change to your LDAP server internal IP
LDAP_BASE_DN="dc=bookcloud,dc=com"
LDAP_BIND_DN="cn=readonly,dc=bookcloud,dc=com"
LDAP_BIND_PASSWORD="123"  # Change this!
ALLOWED_GROUPS="sales hr"  # Space-separated list of allowed groups

################################################################################
# Functions
################################################################################

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d-%H%M%S)"
        print_status "Backed up $file"
    fi
}

################################################################################
# Main Installation Steps
################################################################################

echo "========================================================================"
print_status "LDAP Client Configuration Script"
echo "========================================================================"
echo "LDAP Server: $LDAP_SERVER_IP"
echo "Base DN: $LDAP_BASE_DN"
echo "Allowed Groups: $ALLOWED_GROUPS"
echo "========================================================================"
echo ""

# Step 1: Check if running as root
check_root

# Step 2: Update system and install packages
print_step "Step 1: Installing LDAP client packages (nslcd)..."
export DEBIAN_FRONTEND=noninteractive

# Pre-configure nslcd to avoid prompts
cat > /tmp/nslcd.preseed <<EOF
nslcd nslcd/ldap-uris string ldap://${LDAP_SERVER_IP}/
nslcd nslcd/ldap-base string ${LDAP_BASE_DN}
nslcd nslcd/ldap-binddn string ${LDAP_BIND_DN}
nslcd nslcd/ldap-bindpw password ${LDAP_BIND_PASSWORD}
nslcd nslcd/ldap-starttls boolean false
nslcd nslcd/ldap-reqcert string never
libnss-ldapd libnss-ldapd/nsswitch multiselect passwd, group, shadow
EOF

debconf-set-selections < /tmp/nslcd.preseed
rm /tmp/nslcd.preseed

apt-get update -qq
apt-get install -y libnss-ldapd libpam-ldapd nslcd ldap-utils nscd -qq

print_status "Packages installed successfully"

# Step 3: Stop services before configuration
print_step "Step 2: Stopping services for configuration..."
systemctl stop nslcd || true
systemctl stop nscd || true

# Step 4: Configure /etc/nslcd.conf
print_step "Step 3: Configuring nslcd daemon..."
backup_file /etc/nslcd.conf

cat > /etc/nslcd.conf <<EOF
# LDAP server location
uri ldap://${LDAP_SERVER_IP}

# Base DN for all searches
base ${LDAP_BASE_DN}

# Bind credentials for readonly access
binddn ${LDAP_BIND_DN}
bindpw ${LDAP_BIND_PASSWORD}

# Search bases for different NSS maps
base passwd ou=people,${LDAP_BASE_DN}
base group ou=groups,${LDAP_BASE_DN}
base shadow ou=people,${LDAP_BASE_DN}

# Search scope
scope sub

# LDAP protocol version
ldap_version 3

# Timing/reconnect settings
bind_timelimit 10
timelimit 10
idle_timelimit 3600
reconnect_sleeptime 1
reconnect_retrytime 10

# SSL/TLS settings (disabled for now, enable in production)
ssl no
tls_cacertfile /etc/ssl/certs/ca-certificates.crt

# Filters
filter passwd (objectClass=posixAccount)
filter group (objectClass=posixGroup)

# Attribute mapping
map passwd uid uid
map passwd uidNumber uidNumber
map passwd gidNumber gidNumber
map passwd homeDirectory homeDirectory
map passwd loginShell loginShell
map passwd gecos cn
map shadow uid uid
map group cn cn
map group gidNumber gidNumber
map group member memberUid
EOF

# Set proper permissions
chmod 640 /etc/nslcd.conf
chown root:nslcd /etc/nslcd.conf

print_status "nslcd configuration complete"

# Step 5: Configure /etc/ldap.conf (for PAM)
print_step "Step 4: Configuring LDAP client libraries..."
backup_file /etc/ldap.conf

cat > /etc/ldap.conf <<EOF
# LDAP server configuration
uri ldap://${LDAP_SERVER_IP}
base ${LDAP_BASE_DN}
ldap_version 3

# Bind credentials for readonly access
binddn ${LDAP_BIND_DN}
bindpw ${LDAP_BIND_PASSWORD}

# Search scope
scope sub

# Timeout settings
bind_timelimit 30
timelimit 30
idle_timelimit 3600

# NSS base configurations
nss_base_passwd ou=people,${LDAP_BASE_DN}?one
nss_base_shadow ou=people,${LDAP_BASE_DN}?one
nss_base_group  ou=groups,${LDAP_BASE_DN}?one

# SSL/TLS settings
ssl no
tls_cacertfile /etc/ssl/certs/ca-certificates.crt
EOF

# Step 6: Configure /etc/ldap/ldap.conf
backup_file /etc/ldap/ldap.conf

cat > /etc/ldap/ldap.conf <<EOF
BASE    ${LDAP_BASE_DN}
URI     ldap://${LDAP_SERVER_IP}
EOF

print_status "LDAP client configuration complete"

# Step 7: Configure NSS
print_step "Step 5: Configuring Name Service Switch (NSS)..."
backup_file /etc/nsswitch.conf

sed -i 's/^passwd:.*/passwd:         files systemd ldap/' /etc/nsswitch.conf
sed -i 's/^group:.*/group:          files systemd ldap/' /etc/nsswitch.conf
sed -i 's/^shadow:.*/shadow:         files ldap/' /etc/nsswitch.conf

print_status "NSS configuration updated"

# Step 8: Start services and test connectivity
print_step "Step 6: Starting LDAP services and testing connectivity..."

systemctl start nslcd
systemctl enable nslcd
systemctl start nscd
systemctl enable nscd

sleep 3  # Give services time to start

# Check if nslcd is running
if systemctl is-active --quiet nslcd; then
    print_status "✓ nslcd service is running"
else
    print_error "✗ nslcd service failed to start!"
    systemctl status nslcd
    exit 1
fi

# Test LDAP connectivity
if ldapsearch -x -H ldap://${LDAP_SERVER_IP} -b "${LDAP_BASE_DN}" -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASSWORD}" "(objectClass=posixAccount)" >/dev/null 2>&1; then
    print_status "✓ LDAP connection successful!"
else
    print_error "✗ LDAP connection failed! Please check your settings."
    print_error "Server: ldap://${LDAP_SERVER_IP}"
    print_error "Base DN: ${LDAP_BASE_DN}"
    journalctl -u nslcd -n 20
    exit 1
fi

# Clear NSS caches
nscd -i passwd
nscd -i group

sleep 2

# Test NSS lookup
print_status "Testing NSS user lookup..."
if getent passwd | grep -q "salesuser1"; then
    print_status "✓ NSS user lookup working!"
else
    print_warning "⚠ NSS user lookup not working yet, checking nslcd..."
    journalctl -u nslcd -n 10
fi

# Step 9: Configure PAM - common-auth
print_step "Step 7: Configuring PAM authentication..."
backup_file /etc/pam.d/common-auth

cat > /etc/pam.d/common-auth <<'EOF'
# Local authentication first (keeps sudo working)
auth    [success=2 default=ignore]      pam_unix.so nullok

# LDAP authentication
auth    [success=1 default=ignore]      pam_ldap.so use_first_pass

# Final decisions
auth    requisite                       pam_deny.so
auth    required                        pam_permit.so
auth    optional                        pam_cap.so
EOF

print_status "PAM authentication configured"

# Step 10: Configure PAM - common-account
print_step "Step 8: Configuring PAM account management..."
backup_file /etc/pam.d/common-account

cat > /etc/pam.d/common-account <<'EOF'
# Local accounts first
account [success=2 new_authtok_reqd=done default=ignore]        pam_unix.so

# LDAP accounts
account [success=1 default=ignore]      pam_ldap.so

# Final decisions
account requisite                       pam_deny.so
account required                        pam_permit.so
EOF

print_status "PAM account management configured"

# Step 11: Configure PAM - common-session
print_step "Step 9: Configuring PAM session management..."
backup_file /etc/pam.d/common-session

cat > /etc/pam.d/common-session <<'EOF'
session [default=1]                     pam_permit.so
session requisite                       pam_deny.so
session required                        pam_permit.so
session optional                        pam_umask.so
session required                        pam_unix.so

# Create home directory automatically
session required    pam_mkhomedir.so skel=/etc/skel umask=0022

# LDAP session
session optional                        pam_ldap.so
session optional                        pam_systemd.so
EOF

print_status "PAM session management configured"

# Step 12: Test sudo still works
print_step "Step 10: Verifying sudo access..."
if sudo -n true 2>/dev/null; then
    print_status "✓ Sudo access confirmed working!"
else
    print_warning "⚠ Sudo test inconclusive (this is normal if not in sudo session)"
fi

# Step 13: Configure access control
print_step "Step 11: Configuring group-based access control..."
backup_file /etc/security/access.conf

# Add access rules
cat >> /etc/security/access.conf <<EOF

# ============================================================
# LDAP SSH Access Control - Added by setup script
# ============================================================
# Allow LDAP groups
$(for group in $ALLOWED_GROUPS; do echo "+ : $group : ALL"; done)

# Allow local admin users
+ : sudo : ALL
+ : root : ALL

# Deny everyone else
- : ALL : ALL
EOF

print_status "Access control rules configured"

# Step 14: Configure SSH PAM
print_step "Step 12: Configuring SSH PAM..."
backup_file /etc/pam.d/sshd

# Check if pam_access.so is already configured
if ! grep -q "pam_access.so" /etc/pam.d/sshd; then
    # Add after @include common-auth
    sed -i '/^@include common-auth/a account    required     pam_access.so' /etc/pam.d/sshd
    print_status "Added pam_access.so to SSH PAM configuration"
else
    print_status "pam_access.so already configured in SSH PAM"
fi

# Step 15: Configure SSH server
print_step "Step 13: Configuring SSH server..."
backup_file /etc/ssh/sshd_config

# Ensure PAM is enabled
if ! grep -q "^UsePAM yes" /etc/ssh/sshd_config; then
    echo "UsePAM yes" >> /etc/ssh/sshd_config
fi

# Enable password authentication
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config

print_status "SSH server configured"

# Step 16: Final restart of all services
print_step "Step 14: Restarting all services..."

systemctl restart nslcd
systemctl restart nscd
systemctl restart sshd

sleep 3

# Clear caches again
nscd -i passwd
nscd -i group
nscd -i shadow

print_status "All services restarted"

# Step 17: Final verification
print_step "Step 15: Running final verification tests..."

echo ""
print_status "Checking service status..."
systemctl is-active --quiet nslcd && print_status "✓ nslcd is running" || print_error "✗ nslcd is not running"
systemctl is-active --quiet nscd && print_status "✓ nscd is running" || print_error "✗ nscd is not running"
systemctl is-active --quiet sshd && print_status "✓ sshd is running" || print_error "✗ sshd is not running"

echo ""
print_status "Testing LDAP user lookup via NSS..."
if getent passwd salesuser1 >/dev/null 2>&1; then
    print_status "✓ Can lookup LDAP users via NSS"
    getent passwd salesuser1
else
    print_warning "✗ Cannot lookup LDAP users via NSS"
    print_warning "Checking nslcd logs..."
    journalctl -u nslcd -n 10 --no-pager
fi

echo ""
print_status "Testing LDAP group lookup..."
if getent group sales >/dev/null 2>&1; then
    print_status "✓ Can lookup LDAP groups via NSS"
    getent group sales
else
    print_warning "✗ Cannot lookup LDAP groups via NSS"
fi

echo ""
print_status "Testing user ID resolution..."
if id salesuser1 >/dev/null 2>&1; then
    print_status "✓ User ID resolution working"
    id salesuser1
else
    print_warning "✗ User ID resolution not working"
fi

################################################################################
# Summary
################################################################################

echo ""
echo "========================================================================"
print_status "LDAP Client Configuration Complete!"
echo "========================================================================"
echo ""
echo "Configuration Summary:"
echo "  - LDAP Server: ldap://${LDAP_SERVER_IP}"
echo "  - Base DN: ${LDAP_BASE_DN}"
echo "  - Bind DN: ${LDAP_BIND_DN}"
echo "  - Allowed Groups: ${ALLOWED_GROUPS}"
echo ""
echo "Services Status:"
systemctl is-active --quiet nslcd && echo "  ✓ nslcd: Running" || echo "  ✗ nslcd: Not running"
systemctl is-active --quiet nscd && echo "  ✓ nscd: Running" || echo "  ✗ nscd: Not running"
systemctl is-active --quiet sshd && echo "  ✓ sshd: Running" || echo "  ✗ sshd: Not running"
echo ""
echo "Backup files created with .backup.TIMESTAMP extension in:"
echo "  - /etc/nslcd.conf"
echo "  - /etc/ldap.conf"
echo "  - /etc/pam.d/*"
echo "  - /etc/ssh/sshd_config"
echo ""
echo "========================================================================"
echo "Next Steps:"
echo "========================================================================"
echo ""
echo "1. Test LDAP user lookup:"
echo "   getent passwd salesuser1"
echo "   id salesuser1"
echo ""
echo "2. Test SSH login from another terminal (KEEP THIS ONE OPEN!):"
echo "   ssh salesuser1@\$(hostname -I | awk '{print \$1}')"
echo ""
echo "3. Watch authentication logs:"
echo "   sudo tail -f /var/log/auth.log"
echo ""
echo "4. Check nslcd logs if issues:"
echo "   sudo journalctl -u nslcd -f"
echo ""
echo "5. Test from Cloud Shell:"
echo "   gcloud compute ssh $(hostname) --zone=YOUR_ZONE -- -l salesuser1"
echo ""
echo "========================================================================"
print_warning "IMPORTANT: Keep this SSH session open until you verify login works!"
echo "========================================================================"
echo ""

# Display quick test commands
echo "Quick Test Commands:"
echo "-------------------"
echo ""
echo "# Direct LDAP search:"
echo "ldapsearch -x -H ldap://${LDAP_SERVER_IP} -b \"${LDAP_BASE_DN}\" \"(uid=salesuser1)\""
echo ""
echo "# Test NSS integration:"
echo "getent passwd salesuser1"
echo "getent group sales"
echo "id salesuser1"
echo ""
echo "# Check nslcd status:"
echo "sudo systemctl status nslcd"
echo "sudo journalctl -u nslcd -n 20"
echo ""
echo "# Watch auth logs:"
echo "sudo tail -f /var/log/auth.log"
echo ""
echo "# Clear NSS cache if needed:"
echo "sudo nscd -i passwd"
echo "sudo nscd -i group"
echo ""
echo "========================================================================"
