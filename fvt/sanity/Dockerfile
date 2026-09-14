# The platform-wide sanity suite, packaged to run once and exit.
#
# Unlike the rs-mcp traffic runner this image is NOT pulled from registry:5000. That one is built by
# CI from a service repo, because it ships that repo's test suite; this one's source is the directory
# beside this file, in the checkout the systemd unit already reads its compose file from. Pushing it
# through a registry would add a build-and-pull cycle between editing a check and running it, for a
# ~60MB image that takes seconds to build locally.
#
# The suite deliberately has NO dependency beyond pytest: every request goes through stdlib urllib.
# A sanity checker that cannot run because its own dependency failed to install is worse than useless
# — it is a red board that says nothing about the platform.
FROM python:3.12-slim

WORKDIR /suite

# pytest only, pinned to a major so a new release cannot change collection behaviour under a
# scheduled job nobody is watching.
RUN pip install --no-cache-dir "pytest>=8,<10"

COPY conftest.py pytest.ini ./
COPY test_*.py ./

# Unbuffered, so the journal shows progress as the run happens rather than in one burst at exit —
# this is a container whose whole output is read after the fact, from `journalctl`.
ENV PYTHONUNBUFFERED=1

# -p no:cacheprovider: the container is ephemeral and may be read-only; a .pytest_cache it writes
# once and never reads is pure noise.
CMD ["python", "-m", "pytest", ".", "-q", "-p", "no:cacheprovider"]
