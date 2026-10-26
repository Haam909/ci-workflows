# Built from the repo root, as every dotnet container is: a dotnet component
# has no `path`. /.dockerignore narrows the context to what this copies.
# The images come from mcr.microsoft.com, not Docker Hub, so mirror-images.yml
# needn't copy them.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY tests/fixtures/Directory.Build.props tests/fixtures/
COPY tests/fixtures/dotnet-container/DotnetContainer.csproj tests/fixtures/dotnet-container/packages.lock.json tests/fixtures/dotnet-container/
RUN dotnet restore tests/fixtures/dotnet-container/DotnetContainer.csproj --locked-mode
COPY tests/fixtures/dotnet-container/ tests/fixtures/dotnet-container/
ARG VERSION=0.0.0-dev
RUN dotnet publish tests/fixtures/dotnet-container/DotnetContainer.csproj -c Release --no-restore -o /app -p:Version=${VERSION}

FROM mcr.microsoft.com/dotnet/runtime:10.0
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
ENTRYPOINT ["dotnet", "DotnetContainer.dll"]
