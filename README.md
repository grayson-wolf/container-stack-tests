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

The `split-tests-control.py` python script is provided to allow automatic updating of a package's d/t/control. Once
a package has been set up with this test as a git submodule inside debian/tests, running this python script will
generate a `d/t/control` in the proper location which is limited to only those tests which depend on the package
in question.
