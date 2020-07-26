#!/bin/bash

set -eo pipefail

CROSS_ROOT="${CROSS_ROOT:-/opt/cross}"
STAGE_ROOT="${STAGE_ROOT:-/opt/stage}"
BUILD_ROOT="${BUILD_ROOT:-/opt/build}"
BUILD_TARGET=$1

ZLIB_VERSION="${ZLIB_VERSION:-1.2.11}"
JSON_C_VERSION="${JSON_C_VERSION:-0.13.1}"
OPENSSL_VERSION="${OPENSSL_VERSION:-1.1.1f}"
LIBUV_VERSION="${LIBUV_VERSION:-1.34.2}"
LIBWEBSOCKETS_VERSION="${LIBWEBSOCKETS_VERSION:-4.0.1}"

build_zlib() {
	echo "=== Building zlib-${ZLIB_VERSION} (${TARGET})..."
	curl -sLo- https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz | tar xz -C ${BUILD_DIR}
	pushd ${BUILD_DIR}/zlib-${ZLIB_VERSION}
		env CHOST=${TARGET} ./configure --static --archs="-fPIC" --prefix=${STAGE_DIR}
		make -j4 install
	popd
}

build_json-c() {
	echo "=== Building json-c-${JSON_C_VERSION} (${TARGET})..."
	curl -sLo- https://s3.amazonaws.com/json-c_releases/releases/json-c-${JSON_C_VERSION}.tar.gz | tar xz -C ${BUILD_DIR}
	pushd ${BUILD_DIR}/json-c-${JSON_C_VERSION}
		env CFLAGS=-fPIC ./configure --disable-shared --enable-static --prefix=${STAGE_DIR} --host=${TARGET}
		make -j4 install
	popd
}

openssl_target() {
  case $1 in
    i386) echo linux-generic32 ;;
    x86_64) echo linux-x86_64 ;;
    arm|armhf) echo linux-armv4 ;;
    aarch64) echo linux-aarch64 ;;
    mips|mipsel) echo linux-mips32 ;;
    *)
      echo "unsupported target: $1" && exit 1
  esac
}

build_openssl() {
	echo "=== Building openssl-${OPENSSL_VERSION} (${TARGET})..."
	curl -sLo- https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz | tar xz -C ${BUILD_DIR}
	pushd ${BUILD_DIR}/openssl-${OPENSSL_VERSION}
		env CC=gcc CROSS_COMPILE=${TARGET}- CFLAGS="-fPIC -latomic" \
			./Configure $(openssl_target $BUILD_TARGET) --prefix=${STAGE_DIR} \
		&& make -j4 all > /dev/null && make install_sw
	popd
}

build_libuv() {
  echo "=== Building libuv-${LIBUV_VERSION} (${TARGET})..."
	curl -sLo- https://dist.libuv.org/dist/v${LIBUV_VERSION}/libuv-v${LIBUV_VERSION}.tar.gz | tar xz -C ${BUILD_DIR}
	pushd ${BUILD_DIR}/libuv-v${LIBUV_VERSION}
	  ./autogen.sh
		env CFLAGS=-fPIC ./configure --disable-shared --enable-static --prefix=${STAGE_DIR} --host=${TARGET}
		make -j4 install
	popd
}

install_cmake_cross_file() {
	cat << EOF > ${BUILD_DIR}/cross-${TARGET}.cmake
set(CMAKE_SYSTEM_NAME Linux)

set(CMAKE_C_COMPILER "${TARGET}-gcc")
set(CMAKE_CXX_COMPILER "${TARGET}-g++")

set(CMAKE_FIND_ROOT_PATH "${STAGE_DIR}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(OPENSSL_USE_STATIC_LIBS TRUE)
EOF
}

build_libwebsockets() {
	echo "=== Building libwebsockets-${LIBWEBSOCKETS_VERSION} (${TARGET})..."
	curl -sLo- https://github.com/warmcat/libwebsockets/archive/v${LIBWEBSOCKETS_VERSION}.tar.gz | tar xz -C ${BUILD_DIR}
	pushd ${BUILD_DIR}/libwebsockets-${LIBWEBSOCKETS_VERSION}
		sed -i 's/ websockets_shared//g' cmake/LibwebsocketsConfig.cmake.in
		mkdir build && cd build
		cmake -DCMAKE_TOOLCHAIN_FILE=${BUILD_DIR}/cross-${TARGET}.cmake \
		    -DCMAKE_INSTALL_PREFIX=${STAGE_DIR} \
		    -DCMAKE_FIND_LIBRARY_SUFFIXES=".a" \
		    -DCMAKE_EXE_LINKER_FLAGS="-static" \
		    -DLWS_WITHOUT_TESTAPPS=ON \
		    -DLWS_WITH_LIBUV=ON \
		    -DLWS_STATIC_PIC=ON \
		    -DLWS_WITH_SHARED=OFF \
		    -DLWS_UNIX_SOCK=ON \
		    -DLWS_IPV6=ON \
		    ..
		make install
	popd
}

build_ttyd() {
	echo "=== Building ttyd (${TARGET})..."
	rm -rf build && mkdir -p build && cd build
  cmake -DCMAKE_TOOLCHAIN_FILE=${BUILD_DIR}/cross-${TARGET}.cmake \
      -DCMAKE_INSTALL_PREFIX=${STAGE_DIR} \
      -DCMAKE_FIND_LIBRARY_SUFFIXES=".a" \
      -DCMAKE_EXE_LINKER_FLAGS="-static -no-pie -s" \
      -DCMAKE_BUILD_TYPE=RELEASE \
      ..
  make install
}

build() {
	TARGET="$1"
	ALIAS="$2"
	STAGE_DIR="${STAGE_ROOT}/${TARGET}"
	BUILD_DIR="${BUILD_ROOT}/${TARGET}"

  echo "=== Installing toolchain ${ALIAS} (${TARGET})..."
  mkdir -p ${CROSS_ROOT} && export PATH=${PATH}:/opt/cross/bin
  curl -sLo- http://musl.cc/${TARGET}-cross.tgz | tar xz -C ${CROSS_ROOT} --strip-components 1

  echo "=== Building target ${ALIAS} (${TARGET})..."

  rm -rf ${STAGE_DIR} ${BUILD_DIR}
	mkdir -p ${STAGE_DIR} ${BUILD_DIR}
	export PKG_CONFIG_PATH="${STAGE_DIR}/lib/pkgconfig"

	install_cmake_cross_file

	build_zlib
	build_json-c
	build_libuv
	build_openssl
	build_libwebsockets
	build_ttyd
}

case $BUILD_TARGET in
  i386|x86_64|aarch64|mips|mipsel|mips64|mips64el)
    build $1-linux-musl $1
    ;;
  arm)
    build arm-linux-musleabi $1
    ;;
  armhf)
    build arm-linux-musleabihf $1
    ;;
  *)
    echo "usage: $0 i386|x86_64|arm|armhf|aarch64|mips|mipsel|mips64|mips64el" && exit 1
esac
