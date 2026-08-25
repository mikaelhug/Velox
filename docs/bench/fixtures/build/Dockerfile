# Build-timing fixture. `bench-base:local` is a LOCAL retag of alpine made by run.sh, so
# BuildKit can never reach a registry — a build metric must not be a bandwidth metric.
FROM bench-base:local
COPY src/ /src/
RUN cat /src/* > /tmp/all && sha256sum /tmp/all && rm /tmp/all
RUN i=0; while [ $i -lt 200 ]; do echo $i >> /log; i=$((i+1)); done
RUN dd if=/dev/zero of=/blob bs=1M count=256 2>/dev/null && sha256sum /blob && rm /blob
