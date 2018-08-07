FROM golang:1.9-alpine as buildstage

RUN     apk update && apk --no-cache upgrade && \
        apk --no-cache add git

ENV GOPATH /go
WORKDIR /go
RUN go get github.com/osrg/gobgp/cmd/gobgp
RUN go get github.com/osrg/gobgp/cmd/gobgpd

FROM alpine as runstage

COPY --from=buildstage /go/bin/gobgp /usr/bin
COPY --from=buildstage /go/bin/gobgpd /usr/bin

RUN     apk update && apk --no-cache upgrade && \
        apk --no-cache add quagga

ADD entry-bgp.sh /usr/local/bin
RUN chmod 0755 /usr/local/bin/entry-bgp.sh
ADD dev.sh /usr/local/bin
RUN chmod 0755 /usr/local/bin/dev.sh

ENTRYPOINT [ "/usr/local/bin/entry-bgp.sh" ]
