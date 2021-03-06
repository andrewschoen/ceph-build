#!/bin/sh

# This is the script that runs inside Jenkins.
# http://jenkins.ceph.com/job/python-bindings/

set -x
set -e

# Jenkins will set $RELEASE as a parameter in the job configuration.
if $RELEASE ; then
        # This is a formal release. Sign it with the release key.
        export GNUPGHOME=/home/jenkins-build/build/gnupg.ceph-release/
        export KEYID=17ED316D
else
        # This is an automatic build. Sign it with the autobuild key.
        export GNUPGHOME=/home/jenkins-build/build/gnupg.autobuild/
        export KEYID=03C3951A
fi

HOST=$(hostname --short)
echo "Building on ${HOST}"
echo "  DIST=${DIST}"
echo "  BPTAG=${BPTAG}"
echo "  KEYID=${KEYID}"
echo "  WS=$WORKSPACE"
echo "  PWD=$(pwd)"
echo "  BRANCH=$BRANCH"

case $HOST in
gitbuilder-*-rpm*)
        pwd
        rm -rf debian-repo
        rm -rf dist
        rm -f *.changes *.dsc *.gz *.diff

        # Tag tree and update version number in change log and
        # in setup.py before building.

        REPO=rpm-repo
        KEYID=${KEYID:-03C3951A}  # Default is autobuild-key
        BUILDAREA=./rpmbuild
        DIST=el6
        RPM_BUILD=$(lsb_release -s -c)

        cd src/pybind/ceph
        if [ ! -e setup.py ] ; then
            echo "Are we in the right directory"
            exit 1
        fi

        if gpg --list-keys 2>/dev/null | grep -q ${KEYID} ; then
            echo "Signing packages and repo with ${KEYID}"
        else
            echo "Package signing key (${KEYID}) not found"
            echo "Have you set \$GNUPGHOME ? "
            exit 3
        fi

        if ! CREATEREPO=`which createrepo` ; then
            echo "Please install the createrepo package"
            exit 4
        fi

        # Create Tarball
        python setup.py sdist --formats=bztar

        # Build RPM
        mkdir -p rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
        BUILDAREA=`readlink -fn ${BUILDAREA}`   ### rpm wants absolute path
        # XXX make this spec file configurable
        cp python-ceph.spec ${BUILDAREA}/SPECS
        cp dist/*.tar.bz2 ${BUILDAREA}/SOURCES
        echo "buildarea is: ${BUILDAREA}"
        rpmbuild -ba --define "_topdir ${BUILDAREA}" --define "_unpackaged_files_terminate_build 0" ${BUILDAREA}/SPECS/ceph-deploy.spec

        # create repo
        DEST=${REPO}/${DIST}
        mkdir -p ${REPO}/${DIST}
        cp -r ${BUILDAREA}/*RPMS ${DEST}

        # Sign all the RPMs for this release
        rpm_list=`find ${REPO} -name "*.rpm" -print`
        rpm --addsign --define "_gpg_name ${KEYID}" $rpm_list

        # Construct repodata
        for dir in ${DEST}/SRPMS ${DEST}/RPMS/*
        do
            if [ -d $dir ] ; then
                createrepo $dir
                gpg --detach-sign --armor -u ${KEYID} $dir/repodata/repomd.xml
            fi
        done

        mv debian-repo $WORKSPACE/.
        cd $WORKSPACE
        mkdir -p dist
        mv *.changes *.dsc *.deb *.tar.gz dist/.
        ;;

gitbuilder-cdep-deb* | tala* | mira*)
        pwd
        rm -rf rpm-repo dist/* build/rpmbuild
        pwd
        #cd build

        # Tag tree and update version number in change log and
        # in setup.py before building.

        REPO=debian-repo
        COMPONENT=main
        KEYID=${KEYID:-03C3951A}  # default is autobuild keyid
        DEB_DIST="sid wheezy squeeze quantal precise oneiric natty raring"
        DEB_BUILD=$(lsb_release -s -c)
        RELEASE=1

        if [ ! -d debian ] ; then
            echo "Are we in the right directory"
            exit 1
        fi

        if gpg --list-keys 2>/dev/null | grep -q ${KEYID} ; then
            echo "Signing packages and repo with ${KEYID}"
        else
            echo "Package signing key (${KEYID}) not found"
            echo "Have you set \$GNUPGHOME ? "
            exit 3
        fi

        # Clean up any leftover builds
        #rm -f ../ceph-deploy*.dsc ../ceph-deploy*.changes ../ceph-deploy*.deb ../ceph-deploy.tgz
        #rm -rf ./debian-repo

        # Apply backport tag if release build
        # I am going to jump out the window if this is not fixed and removed from the source
        # of this package. There is absolutely **NO** reason why we need to hard code the
        # DEBEMAIL like this.
        if [ $RELEASE -eq 1 ] ; then
            DEB_VERSION=$(dpkg-parsechangelog | sed -rne 's,^Version: (.*),\1, p')
            BP_VERSION=${DEB_VERSION}${BPTAG}
            DEBEMAIL="adeza@redhat.com" dch -D $DIST --force-distribution -b -v "$BP_VERSION" "$comment"
            dpkg-source -b .
        fi

        # Build Package
        echo "Building for dist: $DEB_BUILD"
        dpkg-buildpackage -k$KEYID
        if [ $? -ne 0 ] ; then
            echo "Build failed"
            exit 2
        fi

        # Build Repo
        PKG=../python-ceph.changes
        mkdir -p $REPO/conf
        if [ -e $REPO/conf/distributions ] ; then
            rm -f $REPO/conf/distributions
        fi

        for DIST in  $DEB_DIST ; do
            cat <<EOF >> $REPO/conf/distributions
Codename: $DIST
Suite: stable
Components: $COMPONENT
Architectures: amd64 armhf i386 source
Origin: Inktank
Description: Ceph distributed file system
DebIndices: Packages Release . .gz .bz2
DscIndices: Sources Release .gz .bz2
Contents: .gz .bz2
SignWith: $KEYID

EOF
        done

        echo "Adding package to repo, dist: $DEB_BUILD ($PKG)"
        reprepro --ask-passphrase -b $REPO -C $COMPONENT --ignore=undefinedtarget --ignore=wrongdistribution include $DEB_BUILD $PKG

        mv rpm-repo $WORKSPACE/.
        cd $WORKSPACE
        mkdir -p dist
        ;;
*)
	echo "Can't determine build host type"
        exit 4
        ;;
esac
