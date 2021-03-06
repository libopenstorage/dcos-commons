#!/usr/bin/env bash

# exit immediately on failure
set -e

if [ $# -lt 2 ]; then
    echo "Syntax: $0 <repo-relative/path/to/executable/> <windows|darwin|linux>"
    exit 1
fi

source $TOOLS_DIR/init_paths.sh

if [ -z "$GOPATH" -o -z "$(which go)" ]; then
  echo "Missing GOPATH environment variable or 'go' executable. Please configure a Go build environment."
  exit 1
fi

ORG_PATH=${ORG_PATH:=github.com/mesosphere}
GOPATH_ORG="$GOPATH/src/$ORG_PATH"
GOPATH_EXE_DIR="$GOPATH_ORG/$REPO_NAME/$1"
if [ $2 = "windows" ]; then
    EXE_FILENAME=$(basename $1).exe # dcos-kafka.exe
else
    EXE_FILENAME=$(basename $1)-$2 # dcos-kafka-linux
fi

# Detect Go version to determine:
# - if UPX should be used to compress binaries (Go 1.7+)
# - if vendoring needs to be manually enabled (Go 1.5)
GO_VERSION=$(go version | awk '{print $3}')
UPX_BINARY="" # only enabled for go1.7+
case "$GO_VERSION" in
    go1.[7-9]*|go1.1[0-9]*|go[2-9]*) # go1.7+, go2+ (must come before go1.0-go1.4: support e.g. go1.10)
        UPX_BINARY="$(which upx || which upx-ucl || echo '')" # avoid error code if upx isn't installed
        ;;
    go0.*|go1.[0-4]*) # go0.*, go1.0-go1.4
        echo "Detected Go <=1.4. This is too old, please install Go 1.5+: $(which go) $GO_VERSION"
        exit 1
        ;;
    go1.5*) # go1.5
        export GO15VENDOREXPERIMENT=1
        ;;
    go1.6*) # go1.6
        # no experiment, but also no UPX
        ;;
    *) # ???
        echo "Unrecognized go version: $(which go) $GO_VERSION"
        exit 1
        ;;
esac

# Add symlink from GOPATH which points into the repository directory:
SYMLINK_LOCATION="$GOPATH_ORG/$REPO_NAME"
if [ ! -h "$SYMLINK_LOCATION" -o "$(readlink $SYMLINK_LOCATION)" != "$REPO_ROOT_DIR" ]; then
    echo "Creating symlink from GOPATH=$SYMLINK_LOCATION to REPOPATH=$REPO_ROOT_DIR"
    rm -rf "$SYMLINK_LOCATION"
    mkdir -p "$GOPATH_ORG"
    cd $GOPATH_ORG
    ln -s "$REPO_ROOT_DIR" $REPO_NAME
fi

# Run 'go get'/'go build' from within GOPATH:
cd $GOPATH_EXE_DIR

go get

# optimization: build a native version of the executable and check if the sha1 matches a
# previous native build. if the sha1 matches, then we can skip the rebuild.
NATIVE_FILENAME="native-${EXE_FILENAME}"
NATIVE_SHA1SUM_FILENAME="${NATIVE_FILENAME}.sha1sum"
go build -o $NATIVE_FILENAME
# 'shasum' is available on OSX as well as (most?) Linuxes:
NATIVE_SHA1SUM=$(shasum $NATIVE_FILENAME | awk '{print $1}')

if [ -f $NATIVE_SHA1SUM_FILENAME -a -f $EXE_FILENAME -a "$NATIVE_SHA1SUM" = "$(cat $NATIVE_SHA1SUM_FILENAME)" ]; then
    # build output hasn't changed. skip.
    echo "Skipping rebuild of $EXE_FILENAME: No change to native build"
else
    # build output is missing, or native build changed. build.
    echo "Rebuilding $EXE_FILENAME: Native build SHA1 mismatch or missing output"
    echo $NATIVE_SHA1SUM > $NATIVE_SHA1SUM_FILENAME

    # available GOOS/GOARCH permutations are listed at:
    # https://golang.org/doc/install/source#environment
    CGO_ENABLED=0 GOOS=$2 GOARCH=386 go build -ldflags="-s -w" -o $EXE_FILENAME

    # use upx if:
    # - upx is installed
    # - golang is recent enough to be compatible with upx
    # - the target OS isn't darwin: compressed darwin builds immediately fail with "Killed: 9"
    if [ -n "$UPX_BINARY" -a $2 != "darwin" ]; then
        $UPX_BINARY -q --best $EXE_FILENAME
    else
        echo "Skipping UPX compression of $EXE_FILENAME"
    fi
fi
