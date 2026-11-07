FROM alpine:3.20
RUN apk add --no-cache ffmpeg ca-certificates
ARG TARGETARCH
COPY crucible-server-${TARGETARCH} /usr/local/bin/crucible-server
ENV CRUCIBLE_SERVER_HOME=/config
VOLUME /config
EXPOSE 32500
ENTRYPOINT ["crucible-server"]
CMD ["serve"]
