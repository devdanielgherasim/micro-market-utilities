FROM openjdk:21-slim AS build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    unzip && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    docker-ce-cli \
    maven && \
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash && \
    rm -rf /var/lib/apt/lists/*

FROM openjdk:21-slim

ENV DEBIAN_FRONTEND=noninteractive

COPY --from=build /usr/bin/docker /usr/bin/docker
COPY --from=build /usr/share/keyrings/docker.gpg /usr/share/keyrings/docker.gpg
COPY --from=build /usr/bin/mvn /usr/bin/mvn
COPY --from=build /usr/share/maven /usr/share/maven
COPY --from=build /usr/bin/az /usr/bin/az
COPY --from=build /usr/lib/python* /usr/lib/
COPY --from=build /usr/bin/python* /usr/bin/

ENV JAVA_HOME=/usr/local/openjdk-21
ENV PATH=$JAVA_HOME/bin:/usr/share/maven/bin:$PATH

CMD ["bash"]
