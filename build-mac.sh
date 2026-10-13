#!/usr/bin/env bash
set -e

# *** Check required tools ***

command -v git   >/dev/null || { echo "ERROR: git not found";    exit 1; }
command -v cmake >/dev/null || { echo "ERROR: cmake not found";   exit 1; }
command -v unzip >/dev/null || { echo "ERROR: unzip not found";   exit 1; }
command -v ninja >/dev/null || { echo "ERROR: ninja not found (brew install ninja)"; exit 1; }


# *** Clone aseprite repo ***

if [ ! -d aseprite ]; then
  git clone --recursive --tags https://github.com/aseprite/aseprite.git aseprite \
    || { echo "failed to clone repo"; exit 1; }
else
  git -C aseprite fetch --tags \
    || { echo "failed to fetch repo"; exit 1; }
fi


# *** Get name of newest tag ***

if [ -z "$ASEPRITE_VERSION" ]; then
  ASEPRITE_VERSION=$(git -C aseprite tag --sort=creatordate | tail -n 1)
fi

echo "building $ASEPRITE_VERSION"


# *** Update local aseprite repo to selected tag ***

git -C aseprite clean --quiet -fdx
git -C aseprite submodule foreach --recursive git clean -xfd

git -C aseprite fetch --quiet --depth=1 --no-tags \
  origin "$ASEPRITE_VERSION":"refs/remotes/origin/$ASEPRITE_VERSION" \
  || { echo "failed to fetch tag"; exit 1; }

git -C aseprite reset --quiet --hard "origin/$ASEPRITE_VERSION" \
  || { echo "failed to update repo"; exit 1; }

git -C aseprite submodule update --init --recursive \
  || { echo "failed to update submodules"; exit 1; }


# *** Patch version string in CMakeLists.txt ***

VERSION_NO_V="${ASEPRITE_VERSION#v}"
if [ -f aseprite/src/ver/CMakeLists.txt ]; then
  sed "s/1\.x-dev/$VERSION_NO_V/g" aseprite/src/ver/CMakeLists.txt > aseprite/.ver.tmp \
    || { echo "failed to update version"; exit 1; }
  mv aseprite/.ver.tmp aseprite/src/ver/CMakeLists.txt
fi


# *** Download skia ***

if [ -f aseprite/laf/misc/skia-tag.txt ]; then
  SKIA_VERSION=$(cat aseprite/laf/misc/skia-tag.txt)
elif [[ "$ASEPRITE_VERSION" == *beta* ]]; then
  SKIA_VERSION="m124-08a5439a6b"
else
  SKIA_VERSION="m102-861e4743af"
fi

# Detect native architecture (macos-latest is arm64)
if [ "$(uname -m)" = "arm64" ]; then
  MACOS_ARCH="arm64"
else
  MACOS_ARCH="x64"
fi

SKIA_ZIP_NAME="Skia-macOS-Release-$MACOS_ARCH.zip"
SKIA_DIR="skia-$SKIA_VERSION"

if [ ! -d "$SKIA_DIR" ]; then
  mkdir -p "$SKIA_DIR"
  echo "downloading skia $SKIA_VERSION ($MACOS_ARCH)..."
  curl -sfL -o "skia-download.zip" \
    "https://github.com/aseprite/skia/releases/download/$SKIA_VERSION/$SKIA_ZIP_NAME" \
    || { echo "failed to download skia"; exit 1; }
  unzip -q "skia-download.zip" -d "$SKIA_DIR"
  rm -f skia-download.zip
fi


# *** Build aseprite ***

if [ -d build ]; then
  rm -rf build
fi

cmake -G Ninja \
  -S aseprite \
  -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_POLICY_DEFAULT_CMP0074=NEW \
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW \
  -DCMAKE_POLICY_DEFAULT_CMP0092=NEW \
  -DENABLE_CCACHE=OFF \
  -DLAF_BACKEND=skia \
  -DSKIA_DIR="$(pwd)/$SKIA_DIR" \
  -DSKIA_LIBRARY_DIR="$(pwd)/$SKIA_DIR/out/Release-$MACOS_ARCH" \
  -DSKIA_OPENGL_LIBRARY= \
  || { echo "failed to configure build"; exit 1; }

ninja -C build \
  || { echo "build failed"; exit 1; }


# *** Create output folder ***

OUT_DIR="aseprite-$ASEPRITE_VERSION"
mkdir -p "$OUT_DIR"
echo "# This file is here so Aseprite behaves as a portable program" > "$OUT_DIR/aseprite.ini"
cp -r aseprite/docs "$OUT_DIR/docs"

# Find the .app bundle in build/bin
APP_NAME=""
for candidate in aseprite.app Aseprite.app; do
  if [ -d "build/bin/$candidate" ]; then
    APP_NAME="$candidate"
    break
  fi
done

if [ -z "$APP_NAME" ]; then
  APP_NAME=$(find build/bin -maxdepth 1 -name "*.app" 2>/dev/null \
             | head -n 1 | xargs -n1 basename 2>/dev/null || true)
fi

if [ -z "$APP_NAME" ] || [ ! -d "build/bin/$APP_NAME" ]; then
  echo "ERROR: could not find aseprite .app bundle in build/bin"
  find build/bin -name "*.app" 2>/dev/null || true
  exit 1
fi

echo "copying $APP_NAME to $OUT_DIR/..."
cp -r "build/bin/$APP_NAME" "$OUT_DIR/"

if [ -d build/bin/data ]; then
  cp -r build/bin/data "$OUT_DIR/data"
fi


# *** GitHub workflow context ***

if [ -n "$GITHUB_WORKFLOW" ]; then
  mkdir -p github
  mv "$OUT_DIR" github/
  echo "ASEPRITE_VERSION=$ASEPRITE_VERSION" >> "$GITHUB_OUTPUT"
  echo "done: github/$OUT_DIR"
else
  echo "done: $OUT_DIR/"
fi
