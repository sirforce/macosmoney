#!/bin/bash
# Builds mny-export.jar (+ lib/) — a read-only converter from Microsoft Money .mny files to JSON.
set -euo pipefail
cd "$(dirname "$0")"
REPO=https://repo1.maven.org/maven2
DEPS=(
  com/healthmarketscience/jackcess/jackcess/4.0.5/jackcess-4.0.5.jar
  com/healthmarketscience/jackcess/jackcess-encrypt/4.0.2/jackcess-encrypt-4.0.2.jar
  org/bouncycastle/bcprov-jdk18on/1.78.1/bcprov-jdk18on-1.78.1.jar
  org/apache/commons/commons-lang3/3.14.0/commons-lang3-3.14.0.jar
  commons-logging/commons-logging/1.3.0/commons-logging-1.3.0.jar
)
mkdir -p lib out
for d in "${DEPS[@]}"; do
  f=lib/$(basename "$d")
  if [ ! -f "$f" ]; then
    curl -sfL -o "$f" "$REPO/$d"
    expected=$(curl -sfL "$REPO/$d.sha1" | cut -c1-40)
    actual=$(shasum -a 1 "$f" | cut -c1-40)
    [ "$expected" = "$actual" ] || { echo "Checksum mismatch for $f" >&2; rm -f "$f"; exit 1; }
  fi
done
CP=$(ls lib/*.jar | tr '\n' ':')
javac --release 8 -nowarn -cp "$CP" -d out src/*.java
printf 'Main-Class: MnyExport\nClass-Path: %s\n' "$(cd lib && ls *.jar | sed 's|^|lib/|' | tr '\n' ' ')" > out/MANIFEST.MF
jar cfm mny-export.jar out/MANIFEST.MF -C out .
echo "Built $(pwd)/mny-export.jar"
