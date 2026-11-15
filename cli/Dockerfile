FROM registry.access.redhat.com/hi/kubectl:latest-builder as builder
USER root
RUN dnf -y --setopt=install_weak_deps=0 --nodocs --use-host-config \
      --installroot /output \
      install \
      yq jq sed awk cat bash bash-completion vim-minimal python3 curl git tar gzip ;\
      mkdir /app/lab-bin -p;\
      dnf -y clean all --enablerepo='*'

FROM registry.access.redhat.com/hi/python:3.14
COPY --from=builder /output /
COPY oc /usr/bin/oc
COPY helm /usr/bin/helm
COPY kind /usr/bin/kind
COPY kubectl /usr/bin/kubectl

USER root
# OpenShift web terminal starts interactive non-login bash, which only reads ~/.bashrc.
# UID 65535 has no home by default, so give it one and load bash-completion there.
RUN mkdir -p /etc/bash_completion.d /etc/profile.d && \
    oc completion bash > /etc/bash_completion.d/oc && \
    printf '%s\n' \
      'if [ -f /usr/share/bash-completion/bash_completion ]; then' \
      '  . /usr/share/bash-completion/bash_completion' \
      'elif [ -f /etc/bash_completion ]; then' \
      '  . /etc/bash_completion' \
      'fi' \
      > /etc/profile.d/bash_completion.sh && \
    printf '%s\n' \
      '# Load system bash-completion (provides _get_comp_words_by_ref, etc.)' \
      'if [ -f /etc/profile.d/bash_completion.sh ]; then' \
      '  . /etc/profile.d/bash_completion.sh' \
      'fi' \
      > /tmp/.bashrc && \
    chown -R 65535:65535 /tmp/.bashrc  

COPY entrypoint.sh /entrypoint.sh

USER 65535
WORKDIR /app
ENV HOME=/tmp \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin:/tmp/lab-bin \
    EDITOR=vi
ENTRYPOINT [ "/entrypoint.sh" ]
