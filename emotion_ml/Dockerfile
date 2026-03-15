FROM --platform=linux/amd64 python:3.11-slim

WORKDIR /workspace/emotion_ml

COPY requirements.txt .
RUN pip install uv --no-cache-dir && uv pip install --system --no-cache -r requirements.txt

ENTRYPOINT ["python"]
