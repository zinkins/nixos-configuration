# Byparr v3.0.4 src/utils.py (upstream SHA 454323a02d04a686a7c4ca91296dfc228c21b720),
# adapted to pre-seed a fresh Firefox NSS profile on every request.
import logging
import shutil
import tempfile
import time
from pathlib import Path
from collections.abc import AsyncGenerator
from typing import Annotated, NamedTuple, cast

from fastapi import Header
from invisible_playwright.async_api import InvisiblePlaywright
from playwright.async_api import Browser, BrowserContext, Page
from pydantic import BaseModel, Field

from src.consts import (
    BROWSER_LOCALE,
    LOG_LEVEL,
    PROXY_PASSWORD,
    PROXY_SERVER,
    PROXY_USERNAME,
)

solver_logger = logging.getLogger("playwright_captcha")
solver_logger.handlers.clear()
if LOG_LEVEL == logging.DEBUG:
    solver_logger.addHandler(logging.StreamHandler())
    solver_logger.setLevel(LOG_LEVEL)
else:
    solver_logger.handlers.append(logging.NullHandler())

logger = logging.getLogger("uvicorn.error")
logger.setLevel(LOG_LEVEL)
if len(logger.handlers) == 0:
    logger.addHandler(logging.StreamHandler())


class TimeoutTimer(BaseModel):
    duration: int  # in seconds
    start_time: float = Field(default_factory=time.perf_counter)

    def remaining(self) -> float:
        """Get remaining time in seconds."""
        return max(0, self.duration - (time.perf_counter() - self.start_time))


MIN_WAIT_MS = 1.0


def remaining_ms(timer: TimeoutTimer) -> float:
    """Milliseconds left, never 0 - Playwright reads that as no timeout at all."""
    return max(MIN_WAIT_MS, timer.remaining() * 1000)


class BrowserDepClass(NamedTuple):
    page: Page
    context: BrowserContext


async def get_browser(
    x_proxy_server: Annotated[
        str | None,
        Header(
            alias="X-Proxy-Server",
            description="Override proxy server for this request in protocol://host:port format.",
        ),
    ] = None,
    x_proxy_username: Annotated[
        str | None,
        Header(
            alias="X-Proxy-Username",
        ),
    ] = None,
    x_proxy_password: Annotated[
        str | None,
        Header(
            alias="X-Proxy-Password",
        ),
    ] = None,
) -> AsyncGenerator[BrowserDepClass]:
    """Get InvisiblePlaywright browser instance."""
    header_server = x_proxy_server
    header_username = x_proxy_username
    header_password = x_proxy_password

    proxy_config = None

    if header_server:
        proxy_config = {
            "server": header_server,
            "username": header_username,
            "password": header_password,
        }
    elif PROXY_SERVER:
        proxy_config = {
            "server": PROXY_SERVER,
            "username": PROXY_USERNAME,
            "password": PROXY_PASSWORD,
        }

    # Non-persistent Playwright creates its own fresh Firefox profile, so
    # modifying a shared NSS database has no effect. Each request instead
    # gets an independent, pre-seeded profile. Nothing is shared between users.
    with tempfile.TemporaryDirectory(prefix="byparr-firefox-nss-") as profile_dir:
        template = Path("/etc/byparr-nss-profile")
        profile = Path(profile_dir)
        if not (template / "cert9.db").is_file():
            raise RuntimeError("NSS distrust profile unavailable; refusing browser startup")
        for filename in ("cert9.db", "key4.db", "pkcs11.txt"):
            source = template / filename
            if source.is_file():
                shutil.copyfile(source, profile / filename)

        # The persistent API returns BrowserContext directly (not Browser).
        # Using a fresh temp directory keeps the original stateless semantics.
        async with InvisiblePlaywright(
            headless=True,
            proxy=proxy_config,
            humanize=True,
            locale=BROWSER_LOCALE or "auto",
            profile_dir=profile_dir,
            extra_prefs={
                "devtools.jsonview.enabled": False,
                "browser.tabs.remote.useCrossOriginOpenerPolicy": False,
                "browser.tabs.remote.useCrossOriginEmbedderPolicy": False,
            },
        ) as context_raw:
            context = cast("BrowserContext", context_raw)
            page = await context.new_page()
            yield BrowserDepClass(page, context)
