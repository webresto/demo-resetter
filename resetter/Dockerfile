FROM python:3.12-alpine
RUN pip install --no-cache-dir docker croniter
COPY resetter.py /resetter.py
ENTRYPOINT ["python", "/resetter.py"]
