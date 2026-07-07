FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --upgrade pip && pip install -r requirements.txt

COPY . ./

EXPOSE 8000

# PORT is provided by Container Apps; default to 8000 locally.
CMD ["sh", "-c", "uvicorn responses_app:app --host 0.0.0.0 --port ${PORT:-8000}"]
