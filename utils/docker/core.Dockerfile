FROM swift:6.2-jammy AS builder
WORKDIR /workspace
COPY Package.swift ./
COPY Sources ./Sources
RUN swift build -c release --product Core

FROM swift:6.2-jammy
WORKDIR /app
COPY --from=builder /workspace/.build/release/Core /app/Core
COPY slopoverlord.config.json /app/slopoverlord.config.json
EXPOSE 251018
CMD ["/app/Core"]
