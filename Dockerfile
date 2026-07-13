# syntax=docker/dockerfile:1.7

#####################
# Stage 1: builder
#####################
FROM gcc:16 AS builder

ARG OPENLDAP_VERSION=2.6.13
ARG OPENLDAP_DIR=openldap-${OPENLDAP_VERSION}
ARG OPENLDAP_TARBALL=${OPENLDAP_DIR}.tgz
ARG OPENLDAP_URL=https://openldap.org/software/download/OpenLDAP/openldap-release/${OPENLDAP_TARBALL}
ARG PREFIX=/usr/local/openldap

# Build dependencies. libsasl2-modules{,-gssapi-heimdal} are installed so the
# SASL plugin directory we stage actually has the mechanisms we want.
RUN apt-get -y update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        groff-base \
        heimdal-dev \
        libltdl-dev \
        libsasl2-dev \
        libsasl2-modules \
        libsasl2-modules-gssapi-heimdal \
        libssl-dev \
        wget && \
    rm -rf /var/lib/apt/lists/*

# Build OpenLDAP. Backends and overlays are compiled statically into slapd
# (=yes, not =mod) so there are no dlopen'd backend plugins at runtime.
RUN cd /opt && \
    wget -q ${OPENLDAP_URL} && \
    tar xf ${OPENLDAP_TARBALL} && \
    cd ${OPENLDAP_DIR} && \
    ./configure \
        --prefix=${PREFIX} \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --enable-slapd \
        --enable-backends=yes \
        --enable-overlays=yes \
        --disable-bdb --disable-hdb --disable-ndb --disable-sql --disable-wt --disable-perl \
        --with-tls=openssl \
        --with-cyrus-sasl && \
    make depend && \
    make && \
    make install

# Stage everything the runtime needs into /rootfs, mirroring its final paths.
# Walks ldd output of staged binaries AND the SASL plugin dir (SASL mechanisms
# are dlopen'd by filename, so ldd of slapd itself wouldn't find them).
RUN <<'EOF' bash
set -euo pipefail
PREFIX=/usr/local/openldap
MULTIARCH="$(gcc -print-multiarch)"
SASL_DIR="/usr/lib/${MULTIARCH}/sasl2"
DISTROLESS_UID=65532

# Mirror the host's merged-usr layout so /rootfs/lib, /lib64, /bin, /sbin
# stay as symlinks into /usr — otherwise the final COPY tries to overlay a
# directory onto distroless's symlinked /lib and fails.
mkdir -p /rootfs/usr/lib /rootfs/usr/lib64 /rootfs/usr/bin /rootfs/usr/sbin
ln -s usr/lib   /rootfs/lib
ln -s usr/lib64 /rootfs/lib64
ln -s usr/bin   /rootfs/bin
ln -s usr/sbin  /rootfs/sbin

mkdir -p "/rootfs$(dirname "$PREFIX")"
cp -a "$PREFIX" "/rootfs$(dirname "$PREFIX")/"

if [ -d "$SASL_DIR" ]; then
    mkdir -p "/rootfs${SASL_DIR}"
    cp -a "$SASL_DIR/." "/rootfs${SASL_DIR}/"
fi

# Collect every shared-lib path ldd resolves for anything we've staged.
{
    find "/rootfs${PREFIX}" -type f -executable
    [ -d "/rootfs${SASL_DIR}" ] && find "/rootfs${SASL_DIR}" -type f -name '*.so*'
} | while read -r f; do
    ldd "$f" 2>/dev/null || true
done | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | sort -u > /tmp/libs.txt

# Copy each resolved lib (following symlinks, keeping the chain).
while read -r lib; do
    [ -e "$lib" ] || continue
    case "$lib" in /rootfs/*) continue ;; esac
    target="$lib"
    while [ -L "$target" ]; do
        dest="/rootfs${target}"
        mkdir -p "$(dirname "$dest")"
        cp -a "$target" "$dest"
        next="$(readlink "$target")"
        case "$next" in
            /*) target="$next" ;;
            *)  target="$(dirname "$target")/$next" ;;
        esac
    done
    if [ -e "$target" ] && [ ! -e "/rootfs${target}" ]; then
        dest="/rootfs${target}"
        mkdir -p "$(dirname "$dest")"
        cp -a "$target" "$dest"
    fi
done < /tmp/libs.txt

# Runtime dirs, pre-chowned to the distroless nonroot user (65532:65532).
mkdir -p /rootfs/var/lib/openldap /rootfs/var/run/openldap /rootfs/etc/openldap/slapd.d

# Schema files. Installed under sysconfdir (/etc/openldap/schema), which the
# $PREFIX copy above doesn't cover. They're needed at runtime so the init
# container's `slaptest -f slapd.conf -F slapd.d` can resolve the schema
# `include` directives when converting slapd.conf to the cn=config tree.
cp -a /etc/openldap/schema /rootfs/etc/openldap/

chown -R "${DISTROLESS_UID}:${DISTROLESS_UID}" \
    /rootfs/var/lib/openldap \
    /rootfs/var/run/openldap \
    /rootfs/etc/openldap

# Verify: nothing in the staged tree has unresolved deps.
: > /tmp/missing.txt
find "/rootfs${PREFIX}" "/rootfs${SASL_DIR}" -type f \( -executable -o -name '*.so*' \) 2>/dev/null | while read -r f; do
    if ldd "$f" 2>&1 | grep -q "not found"; then
        echo "$f" >> /tmp/missing.txt
    fi
done
if [ -s /tmp/missing.txt ]; then
    echo "ERROR: unresolved library deps in staged tree:"
    while read -r f; do
        echo "==> $f"
        ldd "$f" | grep "not found" || true
    done < /tmp/missing.txt
    exit 1
fi

# Sanity check: slapd reports its version + features cleanly.
"${PREFIX}/libexec/slapd" -VV
EOF

# slapd sizes (and zero-initializes) its connection table from the soft
# RLIMIT_NOFILE, and container runtimes commonly hand out limits in the
# billions (containerd with LimitNOFILE=infinity), which OOM-kills the pod
# during startup. Distroless has no shell for ulimit, so a static wrapper
# caps the soft limit before exec'ing slapd.
RUN <<'EOF' bash
set -euo pipefail
cat > /tmp/slapd-fdcap.c <<'EOC'
#include <sys/resource.h>
#include <unistd.h>

#define FD_CAP 8192
static const char SLAPD[] = "/usr/local/openldap/libexec/slapd";

int main(int argc, char **argv) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur > FD_CAP) {
        rl.rlim_cur = FD_CAP;
        setrlimit(RLIMIT_NOFILE, &rl);
    }
    argv[0] = (char *)SLAPD;
    execv(SLAPD, argv);
    return 127;
}
EOC
gcc -O2 -static -o /rootfs/usr/local/openldap/libexec/slapd-fdcap /tmp/slapd-fdcap.c
EOF

#####################
# Stage 2: runtime
#####################
FROM gcr.io/distroless/base-debian13:nonroot

COPY --from=builder /rootfs/ /

EXPOSE 1389 1636

USER nonroot:nonroot
ENTRYPOINT ["/usr/local/openldap/libexec/slapd-fdcap"]
# Foreground, log to stderr (-d implies foreground in OpenLDAP). High ports
# because the nonroot user can't bind the privileged LDAP defaults.
CMD ["-d", "256", "-h", "ldap://:1389/ ldaps://:1636/"]
