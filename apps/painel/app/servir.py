"""Inicia o gunicorn (1 worker, threads) no endereço PAINEL_BIND:PAINEL_PORTA."""
import os
import sys

bind = os.environ.get("PAINEL_BIND", "0.0.0.0")
porta = os.environ.get("PAINEL_PORTA", "9049")
if os.environ.get("PAINEL_MODO_TESTE") == "1" and bind not in ("127.0.0.1", "::1"):
    sys.exit("PAINEL_MODO_TESTE=1 só é permitido com PAINEL_BIND=127.0.0.1 (nunca em produção).")
os.execvp("gunicorn", ["gunicorn", "--chdir", "/app", "-k", "gthread", "-w", "1", "--threads", "6",
                       "-b", f"{bind}:{porta}", "--access-logfile", "-", "--timeout", "60", "painel:app"])
