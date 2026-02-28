FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY collect.py schwab_setup.py plaid_setup.py ./

# /secrets is mounted from the host for persistent token files (e.g. Schwab OAuth token)
VOLUME ["/secrets"]

# Run the collector once on start, then every hour
CMD ["sh", "-c", "python collect.py && while sleep 3600; do python collect.py; done"]
