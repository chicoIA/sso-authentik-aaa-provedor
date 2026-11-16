FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN pip install --no-cache-dir flask==3.0.3 gunicorn==22.0.0 requests==2.32.3 tzdata==2024.1 \
 && useradd -u 10001 -m painel && mkdir /dados && chown painel /dados
WORKDIR /app
COPY app/ /app/
USER painel
EXPOSE 9049
CMD ["python", "-I", "/app/servir.py"]
