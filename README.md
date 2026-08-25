# container-stack-tests

Shared autopkgtest suite for the Ubuntu container stack.

This repository centralizes the autopkgtest logic that used to live in
each of the container packages:
- `containerd-app`
- `containerd-stable`
- `docker-buildx`
- `docker-compose-v2`
- `docker.io-app`
- `runc-app`
- `runc-stable`

Right now the tests are in the form of a metapackage; this might change
upon our decision of where and how to run them. For now this just serves
as an easy way to run all the tests.
