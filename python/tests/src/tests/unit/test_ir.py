import logging
from dataclasses import dataclass
from typing import Optional
from unittest.mock import MagicMock

import pytest

from ambassador.ir import IR
from ambassador.ir.irbasemapping import IRBaseMapping

from tests.utils import (
    Compile,
    default_http3_listener_manifest,
    default_listener_manifests,
    default_tcp_listener_manifest,
    default_udp_listener_manifest,
    generate_istio_cert_delta,
    logger,
)


def http3_quick_start_manifests():
    return default_listener_manifests() + default_http3_listener_manifest()


class TestIR:
    def test_http3_enabled(self, caplog):
        caplog.set_level(logging.WARNING, logger="ambassador")

        @dataclass
        class TestCase:
            name: str
            inputYaml: str
            expected: dict[str, bool]
            expectedLog: Optional[str] = None

        testcases = [
            TestCase(
                "quick-start",
                default_listener_manifests(),
                {"tcp-0.0.0.0-8080": False, "tcp-0.0.0.0-8443": False},
            ),
            TestCase(
                "quick-start-with_http3",
                http3_quick_start_manifests(),
                {
                    "tcp-0.0.0.0-8080": False,
                    "tcp-0.0.0.0-8443": True,
                    "udp-0.0.0.0-8443": True,
                },
            ),
            TestCase(
                "http3-only",
                default_http3_listener_manifest(),
                {"udp-0.0.0.0-8443": True},
            ),
            TestCase("raw-udp", default_udp_listener_manifest(), {}),
            TestCase("raw-tcp", default_tcp_listener_manifest(), {"tcp-0.0.0.0-8443": False}),
        ]

        for case in testcases:
            compiled_ir = Compile(logger, case.inputYaml, k8s=True)
            result_ir = compiled_ir["ir"]

            listeners = result_ir.listeners

            assert len(case.expected.items()) == len(listeners)

            for listener_id, http3_enabled in case.expected.items():
                listener = listeners.get(listener_id, None)
                assert listener is not None
                assert listener.http3_enabled == http3_enabled

            if case.expectedLog is not None:
                assert case.expectedLog in caplog.text


    @pytest.mark.parametrize(
        "name, has_cache, deltas, expected",
        [
            # Regression for #4744: a cache exists but the snapshot had no deltas
            # (e.g., Istio rotated the mTLS cert and the istio-certs Secret has
            # no matching K8s resource to emit a delta for). We must force a
            # complete reconfigure so the stale cache gets cleared.
            (
                "cached-no-deltas",
                True,
                [],
                {"config_type": "complete", "reset_cache": True, "invalidate_groups_for": []},
            ),
            # Cache exists with a non-Mapping delta (e.g., a Secret update): there's
            # nothing to invalidate incrementally, so it's still a complete reconfigure.
            (
                "cached-non-mapping-delta",
                True,
                [generate_istio_cert_delta()],
                {"config_type": "complete", "reset_cache": True, "invalidate_groups_for": []},
            ),
            # Cache exists with a Mapping delta: invalidate incrementally.
            (
                "cached-mapping-delta",
                True,
                [{"kind": "Mapping", "metadata": {"name": "foo", "namespace": "bar"}}],
                {
                    "config_type": "incremental",
                    "reset_cache": False,
                    "invalidate_groups_for": [
                        IRBaseMapping.make_cache_key("Mapping", "foo", "bar"),
                    ],
                },
            ),
            # No cache: always a complete reconfigure.
            (
                "no-cache-with-deltas",
                False,
                [generate_istio_cert_delta()],
                {"config_type": "complete", "reset_cache": True, "invalidate_groups_for": []},
            ),
            (
                "no-cache-no-deltas",
                False,
                [],
                {"config_type": "complete", "reset_cache": True, "invalidate_groups_for": []},
            ),
        ],
    )
    def test_check_deltas(self, name, has_cache, deltas, expected, caplog):
        caplog.set_level(logging.DEBUG, logger="ambassador")

        fetcher = MagicMock()
        fetcher.deltas = deltas
        cache = MagicMock() if has_cache else None

        config_type, reset_cache, invalidate_groups_for = IR.check_deltas(
            logger=logger, fetcher=fetcher, cache=cache,
        )

        assert config_type == expected["config_type"]
        assert reset_cache == expected["reset_cache"]
        assert invalidate_groups_for == expected["invalidate_groups_for"]

        # cache.dump is only invoked when we actually walk deltas -- i.e. when
        # we had both a cache and at least one delta to consider.
        if has_cache and deltas:
            cache.dump.assert_called_once()
