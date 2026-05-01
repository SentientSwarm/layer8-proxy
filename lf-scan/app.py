"""lf-scan: thin FastAPI wrapper around llamafirewall library.

Designed to be deleted in agent-locksmith M8 once inline scanners ship.
"""

from fastapi import FastAPI

app = FastAPI(title="lf-scan", version="0.1.0")
