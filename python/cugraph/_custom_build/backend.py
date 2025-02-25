# Copyright (c) 2022-2023, NVIDIA CORPORATION.

"""Custom build backend for cugraph to get versioned requirements.

Based on https://setuptools.pypa.io/en/latest/build_meta.html
"""
import os
from functools import wraps

from setuptools import build_meta as _orig

# Alias the required bits
prepare_metadata_for_build_wheel = _orig.prepare_metadata_for_build_wheel
build_wheel = _orig.build_wheel
build_sdist = _orig.build_sdist


def replace_requirements(func):
    @wraps(func)
    def wrapper(config_settings=None):
        orig_list = getattr(_orig, func.__name__)(config_settings)
        cuda_suffix = os.getenv("RAPIDS_PY_WHEEL_CUDA_SUFFIX", default="")
        append_list = [
            f"rmm{cuda_suffix}==23.4.*",
            f"raft-dask{cuda_suffix}==23.4.*",
            f"pylibcugraph{cuda_suffix}==23.4.*",
        ]
        return orig_list + append_list

    return wrapper


get_requires_for_build_wheel = replace_requirements(_orig.get_requires_for_build_wheel)
get_requires_for_build_sdist = replace_requirements(_orig.get_requires_for_build_sdist)
get_requires_for_build_editable = replace_requirements(
    _orig.get_requires_for_build_editable
)
