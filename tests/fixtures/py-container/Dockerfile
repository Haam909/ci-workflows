# python:3.12-slim, copied to ghcr.io by mirror-images.yml: Docker Hub limits pulls.
FROM ghcr.io/haam909/python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
CMD ["python", "-c", "import app; print(app.status())"]
