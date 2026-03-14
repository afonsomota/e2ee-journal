"""Centralised logging helper.

Every module should get its logger via:
    from log import get_logger
    logger = get_logger(__name__)

This ensures the level from LOG_LEVEL is applied to each logger directly,
bypassing any handler-level filters that uvicorn may have set on the root logger.
"""

import logging
import os

_LEVEL = getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper(), logging.INFO)


def get_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(_LEVEL)
    return logger


def configure_root() -> None:
    """Call once at startup to ensure the root logger can actually emit messages.

    Uvicorn only attaches handlers to its own named loggers (``uvicorn``,
    ``uvicorn.access``), **not** to the root logger.  Without a handler on
    root, any message that propagates up from our app loggers is silently
    dropped.  We add a ``StreamHandler`` when none exists, and lower the
    level on every handler so DEBUG messages aren't filtered out.
    """
    root = logging.getLogger()
    root.setLevel(_LEVEL)

    if not root.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(
            logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
        )
        root.addHandler(handler)

    for handler in root.handlers:
        handler.setLevel(_LEVEL)
