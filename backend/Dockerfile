FROM python:3.12-slim
WORKDIR /app
COPY ph_parse.py server.py ./
# No pip install: stdlib only.
ENV PYTHONUNBUFFERED=1
# Cloady / Render inject $PORT; default 8080 for local runs.
EXPOSE 8080
CMD ["python3", "server.py"]
