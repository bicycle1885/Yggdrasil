using BinaryBuilder, SHA, Dates
include("../common.jl")

# Metadata
name = "Rootfs"
version = VersionNumber("$(year(today())).$(month(today())).$(day(today()))")
host_platform = Linux(:x86_64; libc=:musl)
verbose = "--verbose" in ARGS

# We begin by downloading the alpine rootfs and using THAT as a bootstrap rootfs.
rootfs_url = "https://github.com/gliderlabs/docker-alpine/raw/6e9a4b00609e29210ff3f545acd389bb7e89e9c0/versions/library-3.9/x86_64/rootfs.tar.xz"
rootfs_hash = "9eafcb389d03266f31ac64b4ccd9e9f42f86510811360cd4d4d6acbd519b2dc4"
mkpath(joinpath(@__DIR__, "build"))
mkpath(joinpath(@__DIR__, "products"))
rootfs_tarxz_path = joinpath(@__DIR__, "build", "rootfs.tar.xz")
rootfs_targz_path = joinpath(@__DIR__, "products", "$(name)-stage1.v$(version).$(triplet(host_platform)).tar.gz")
rootfs_squash_path = joinpath(@__DIR__, "products", "$(name)-stage1.v$(version).$(triplet(host_platform)).squashfs")
BinaryBuilder.download_verify(rootfs_url, rootfs_hash, rootfs_tarxz_path; verbose=verbose, force=true)

# Unpack the rootfs (using `tar` on the local machine), then pack it up again (again using tools on the local machine) and squashify it:
rootfs_extracted = joinpath(@__DIR__, "build", "rootfs_extracted")
rm(rootfs_extracted; recursive=true, force=true)
mkpath(rootfs_extracted)
success(`tar -C $(rootfs_extracted) -Jxf $(rootfs_tarxz_path)`)

# In order to launch our rootfs, we need at bare minimum, a sandbox/docker entrypoint.  Ensure those exist.
# We check in `sandbox`, but if it gets modified, we would like it to be updated.  In general, we hope
# to build it inside of BB, but in the worst case, where we've made an incompatible change and the last
# checked-in version of `sandbox` won't do, we need to be able to build it and build it now.  So if
# we're on a compatible platform, and `sandbox` is outdated, build it.
sandbox_path = joinpath(@__DIR__, "bundled", "utils", "sandbox") 
if is_outdated(sandbox_path, "$(sandbox_path).c")
    try
        build_platform = platform_key_abi(String(read(`gcc -dumpmachine`)))
        @assert isa(build_platform, Linux)
        @assert arch(build_platform) == :x86_64
        if verbose
            @info("Rebuilding sandbox for initial bootstrap...")
        end
        success(`gcc -static -static-libgcc -o $(sandbox_path) $(sandbox_path).c`)
    catch
        if isfile(sandbox_path)
            @warn("Sandbox outdated and we can't build it, continuing, but be warned, initial bootstrap might fail!")
        else
            error("Sandbox missing and we can't build it!  Build it somewhere else via `gcc -static -static-libgcc -o sandbox sandbox.c`")
        end
    end
end
# Copy in `sandbox` and `docker_entrypoint.sh` since we need those just to get up in the morning.
# Also set up a DNS resolver, since that's important too.  Yes, this work is repeated below, but
# we need a tiny world to set up our slightly larger world inside of.
cp(sandbox_path, joinpath(rootfs_extracted, "sandbox"); force=true)
cp(joinpath(@__DIR__, "bundled", "utils", "docker_entrypoint.sh"), joinpath(rootfs_extracted, "docker_entrypoint.sh"); force=true)
open(joinpath(rootfs_extracted, "etc", "resolv.conf"), "w") do io
    for resolver in ["8.8.8.8", "8.8.4.4", "4.4.4.4", "1.1.1.1"]
        println(io, "nameserver $(resolver)")
    end
end
# we really like bash, and it's annoying to have to polymorphise, so just lie for the stage 1 bootstrap
cp(joinpath(@__DIR__, "bundled", "utils", "fake_bash.sh"), joinpath(rootfs_extracted, "bin", "bash"); force=true)
cp(joinpath(@__DIR__, "bundled", "utils", "profile"), joinpath(rootfs_extracted, "etc", "profile"); force=true)
cp(joinpath(@__DIR__, "bundled", "utils", "profile.d"), joinpath(rootfs_extracted, "etc", "profile.d"); force=true)
success(`tar -C $(rootfs_extracted) -czf $(rootfs_targz_path) .`)
success(`mksquashfs $(rootfs_extracted) $(rootfs_squash_path) -force-uid 0 -force-gid 0 -comp xz -b 1048576 -Xdict-size 100% -noappend`)

# Slip these barebones rootfs images into our BB install location, overwriting whatever Rootfs shard would be chosen:
if verbose
    @info("Deploying barebones bootstrap RootFS shard...")
end
targz_shard = BinaryBuilder.CompilerShard(name, version, host_platform, :targz)
squash_shard = BinaryBuilder.CompilerShard(name, version, host_platform, :squashfs)
cp(rootfs_targz_path,  BinaryBuilder.download_path(targz_shard); force=true)
cp(rootfs_squash_path, BinaryBuilder.download_path(squash_shard); force=true)

# Insert them into the compiler shard hashtable.  From this point on; BB will use this shard as the RootFS shard,
# because we set `bootstrap=true`.  We also opt-out of any binutils, GCC or clang shards getting mounted.
BinaryBuilder.shard_hash_table[targz_shard] = bytes2hex(open(SHA.sha256, rootfs_targz_path))
BinaryBuilder.shard_hash_table[squash_shard] = bytes2hex(open(SHA.sha256, rootfs_squash_path))
Core.eval(BinaryBuilder, :(bootstrap_mode = true))

if verbose
    @info("Unmounting all shards...")
end
BinaryBuilder.unmount.(keys(BinaryBuilder.shard_hash_table); verbose=verbose)
rm(BinaryBuilder.mount_path(targz_shard); recursive=true, force=true)

# PHWEW.  Okay.  Now, we do some of the same steps over again, but within BinaryBuilder, where
# we can actulaly run tools inside of the rootfs (e.g. if we're building on OSX through docker)


# Sources we build from
sources = [
    "https://github.com/gliderlabs/docker-alpine/raw/6e9a4b00609e29210ff3f545acd389bb7e89e9c0/versions/library-3.9/x86_64/rootfs.tar.xz" =>
    "9eafcb389d03266f31ac64b4ccd9e9f42f86510811360cd4d4d6acbd519b2dc4",
    "./bundled",
]

# Bash recipe for building across all platforms
script = raw"""
# $prefix is our chroot
mv bin dev etc home lib media mnt proc root run sbin srv sys tmp usr var $prefix/
cd $prefix

# Setup DNS resolution
printf '%s\n' \
    "nameserver 8.8.8.8" \
    "nameserver 8.8.4.4" \
    "nameserver 4.4.4.4" \
    > etc/resolv.conf

# Insert system mountpoints
touch ./dev/{null,ptmx,urandom}
mkdir ./dev/{pts,shm}

## Install foundational packages within the chroot
NET_TOOLS="curl wget git openssl ca-certificates"
MISC_TOOLS="python sudo file libintl patchutils grep"
FILE_TOOLS="tar zip unzip xz findutils squashfs-tools unrar rsync"
INTERACTIVE_TOOLS="bash gdb vim nano tmux strace"
BUILD_TOOLS="make patch gawk autoconf automake libtool bison flex pkgconfig cmake ninja ccache"
apk add --update --root $prefix ${NET_TOOLS} ${MISC_TOOLS} ${FILE_TOOLS} ${INTERACTIVE_TOOLS} ${BUILD_TOOLS}

# chgrp and chown should be no-ops since we run in a single-user mode
rm -f ./bin/{chown,chgrp}
touch ./bin/{chown,chgrp}
chmod +x ./bin/{chown,chgrp}

# Install utilities we'll use.  Many of these are compatibility shims, look at
# the files themselves to discover why we use them.
mkdir -p ./usr/local/bin ./usr/local/share/configure_scripts
cp $WORKSPACE/srcdir/utils/tar_wrapper.sh ./usr/local/bin/tar
cp $WORKSPACE/srcdir/utils/update_configure_scripts.sh ./usr/local/bin/update_configure_scripts
cp $WORKSPACE/srcdir/utils/fake_uname.sh ./usr/local/bin/uname
cp $WORKSPACE/srcdir/utils/fake_sha512sum.sh ./usr/local/bin/sha512sum
cp $WORKSPACE/srcdir/utils/dual_libc_ldd.sh ./usr/bin/ldd
cp $WORKSPACE/srcdir/utils/atomic_patch.sh ./usr/local/bin/atomic_patch
cp $WORKSPACE/srcdir/utils/config.* ./usr/local/share/configure_scripts/
chmod +x ./usr/local/bin/*

# Deploy configuration
cp $WORKSPACE/srcdir/conf/nsswitch.conf ./etc/nsswitch.conf
cp $WORKSPACE/srcdir/utils/profile ${prefix}/etc/
cp -d $WORKSPACE/srcdir/utils/profile.d/* ${prefix}/etc/profile.d/


# Include GlibcBuilder v2.25 output as our official native x86_64-linux-gnu and i686-linux-gnu loaders.
# We use 2.25 because it is relatively recent and builds with GCC 4.8.5 and Binutils 2.24
mkdir -p /tmp/glibc_extract ${prefix}/lib ${prefix}/lib64
#tar -C /tmp/glibc_extract -zxf $WORKSPACE/srcdir/Glibc*2.25*x86_64-linux-gnu.tar.gz
#tar -C /tmp/glibc_extract -zxf $WORKSPACE/srcdir/Glibc*2.25*i686-linux-gnu.tar.gz
#mv /tmp/glibc_extract/x86_64-linux-gnu/sys-root/lib64/* ${prefix}/lib64/
#ls -la ${prefix}/lib
#mv /tmp/glibc_extract/i686-linux-gnu/sys-root/lib/* ${prefix}/lib/

# Put sandbox and our docker entrypoint script into the root, to be used as `init` replacements.
cp $WORKSPACE/srcdir/utils/sandbox ${prefix}/sandbox
chmod +x ${prefix}/sandbox
cp $WORKSPACE/srcdir/utils/docker_entrypoint.sh ${prefix}/docker_entrypoint.sh

# Extract a very recent libstdc++.so.6 to /lib64 as well
cp -d $WORKSPACE/srcdir/libs/libstdc++.so* ${prefix}/lib64

# Create /overlay_workdir so that we know we can always mount an overlay there.  Same with /meta
mkdir -p ${prefix}/overlay_workdir ${prefix}/meta


## Cleanup
# We can never extract these files, because they are too fancy  :(
rm -rf ${prefix}/usr/share/terminfo

# Cleanup .pyc/.pyo files as they're not redistributable
find ${prefix}/usr -type f -name "*.py[co]" -delete -or -type d -name "__pycache__" -delete
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = [host_platform]

# The products that we will ensure are always built
products(prefix) = Product[
    ExecutableProduct(prefix, "sandbox", :sandbox),
]

# Dependencies that must be installed before this package can be built
dependencies = [
]

# Build the tarball
build_info = build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; skip_audit=true)
