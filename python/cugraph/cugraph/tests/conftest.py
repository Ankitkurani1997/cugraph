# Copyright (c) 2021-2022, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import pytest
import os
from dask_cuda import LocalCUDACluster
from dask.distributed import Client
from cugraph.dask.comms import comms as Comms

import rmm

from cugraph.testing.mg_utils import start_dask_client, stop_dask_client

# module-wide fixtures


# Spoof the gpubenchmark fixture if it's not available so that asvdb and
# rapids-pytest-benchmark do not need to be installed to run tests.
if "gpubenchmark" not in globals():

    def benchmark_func(func, *args, **kwargs):
        return func(*args, **kwargs)

    @pytest.fixture
    def gpubenchmark():
        return benchmark_func


@pytest.fixture(scope="module")
def dask_client():
    n_devices = os.getenv('DASK_NUM_WORKERS', 4)
    n_devices = int(n_devices)

    visible_devices = ','.join([str(i) for i in range(1, n_devices+1)])

    cluster = LocalCUDACluster(protocol='tcp', rmm_pool_size='25GB', CUDA_VISIBLE_DEVICES=visible_devices)
    client = Client(cluster)
    Comms.initialize(p2p=True)
    rmm.reinitialize(pool_allocator=True)

    yield client

    stop_dask_client(client)
    print("\ndask_client fixture: client.close() called")
