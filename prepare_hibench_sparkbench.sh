#!/usr/bin/env bash
set -euo pipefail

# Build HiBench SparkBench assembly jar (micro module by default) and print the jar path.
#
# Uses JDK 8 for the build (see prepare_jdk8.sh) because the scala-maven-plugin used by
# this archived HiBench version is not reliable on Java 11+.

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}"

HIBENCH_HOME="${HIBENCH_HOME:-$DATA_DIR/hibench_src}"
if [ ! -f "$HIBENCH_HOME/pom.xml" ]; then
  echo "ERROR: HiBench not found at HIBENCH_HOME=$HIBENCH_HOME" >&2
  echo "hint: clone it first: git clone https://github.com/Intel-bigdata/HiBench.git $HIBENCH_HOME" >&2
  exit 1
fi

SPARK_PROFILE="${SPARK_PROFILE:-3.1}"     # matches sparkbench/pom.xml profiles: 2.4 / 3.0 / 3.1
SCALA_PROFILE="${SCALA_PROFILE:-2.12}"    # for Spark 3.x
MODULES_PROFILE="${MODULES_PROFILE:-micro}" # micro|ml|sql|graph|websearch|...

JAR="$HIBENCH_HOME/sparkbench/assembly/target/sparkbench-assembly-8.0-SNAPSHOT-dist.jar"
if [ -s "$JAR" ]; then
  echo "$JAR"
  exit 0
fi

JAVA8_HOME="$("$ROOT_DIR/prepare_jdk8.sh")"
export JAVA_HOME="$JAVA8_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

echo "=== build HiBench SparkBench (module=$MODULES_PROFILE spark=$SPARK_PROFILE scala=$SCALA_PROFILE) ===" >&2
cd "$HIBENCH_HOME"
mvn -Psparkbench -Dmodules -P"$MODULES_PROFILE" -Dspark="$SPARK_PROFILE" -Dscala="$SCALA_PROFILE" -DskipTests clean package -q

test -s "$JAR" || { echo "ERROR: expected sparkbench assembly jar not found: $JAR" >&2; exit 1; }
echo "$JAR"

