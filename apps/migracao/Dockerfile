# Ferramenta de migração daloRADIUS -> authentik (roda sob demanda, não é serviço).
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ .
RUN chmod +x coletar_ambiente_atual.sh
ENTRYPOINT ["python", "/app/migrar_daloradius.py"]
