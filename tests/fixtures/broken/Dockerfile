# Test fixture for tests/remote-deploy.test.sh: the container starts, but /healthz returns 500.
FROM nginxinc/nginx-unprivileged:1.30.6-alpine
COPY default.conf /etc/nginx/conf.d/default.conf
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=2 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
