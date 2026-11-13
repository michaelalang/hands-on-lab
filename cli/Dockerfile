FROM registry.access.redhat.com/hi/kubectl:latest-builder as builder
USER root
RUN dnf -y --setopt=install_weak_deps=0 --nodocs --use-host-config \
      --installroot /output \
      install \
      yq jq sed awk cat bash python3 curl git tar gzip ;\
      mkdir /app/lab-bin -p;\
      dnf -y clean all --enablerepo='*'

FROM registry.access.redhat.com/hi/python:3.14
COPY --from=builder /output /
COPY oc /usr/bin/oc
COPY helm /usr/bin/helm
COPY kind /usr/bin/kind
COPY kubectl /usr/bin/kubectl

COPY entrypoint.sh /entrypoint.sh

USER 65535
WORKDIR /app
ENV PATH=/usr/bin:/bin:/usr/sbin:/sbin
ENTRYPOINT [ "/entrypoint.sh" ]
