# =============================================================================
# Copyright (c) 2022-2023, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied. See the License for the specific language governing permissions and limitations under
# the License.
# =============================================================================

cmake_minimum_required(VERSION 3.23.1 FATAL_ERROR)

set(cugraph_version 23.04.00)

include(../../fetch_rapids.cmake)

# We always need CUDA for cuML because the raft dependency brings in a
# header-only cuco dependency that enables CUDA unconditionally.
include(rapids-cuda)
rapids_cuda_init_architectures(cugraph-python)

project(
  cugraph-python
  VERSION ${cugraph_version}
  LANGUAGES # TODO: Building Python extension modules via the python_extension_module requires the C
            # language to be enabled here. The test project that is built in scikit-build to verify
            # various linking options for the python library is hardcoded to build with C, so until
            # that is fixed we need to keep C.
            C CXX CUDA
)

################################################################################
# - User Options  --------------------------------------------------------------
option(FIND_CUGRAPH_CPP "Search for existing CUGRAPH C++ installations before defaulting to local files"
       OFF
)
option(CUGRAPH_BUILD_WHEELS "Whether this build is generating a Python wheel." OFF)
option(USE_CUGRAPH_OPS "Enable all functions that call cugraph-ops" ON)

if(NOT USE_CUGRAPH_OPS)
    message(STATUS "Disabling libcugraph functions that reference cugraph-ops")
    add_compile_definitions(NO_CUGRAPH_OPS)
endif()

# If the user requested it,  we attempt to find CUGRAPH.
if(FIND_CUGRAPH_CPP)
  find_package(cugraph ${cugraph_version} REQUIRED)
else()
  set(cugraph_FOUND OFF)
endif()

include(rapids-cython)

if(NOT cugraph_FOUND)
  set(BUILD_TESTS OFF)
  set(BUILD_CUGRAPH_MG_TESTS OFF)
  set(BUILD_CUGRAPH_OPS_CPP_TESTS OFF)

  set(_exclude_from_all "")
  if(CUGRAPH_BUILD_WHEELS)
    # Statically link dependencies if building wheels
    set(CUDA_STATIC_RUNTIME ON)
    set(USE_RAFT_STATIC ON)
    set(CUGRAPH_COMPILE_RAFT_DIST_LIBS OFF)
    set(CUGRAPH_USE_CUGRAPH_OPS_STATIC ON)
    set(CUGRAPH_EXCLUDE_CUGRAPH_OPS_FROM_ALL ON)
    set(ALLOW_CLONE_CUGRAPH_OPS ON)

    # Don't install the cuML C++ targets into wheels
    set(_exclude_from_all EXCLUDE_FROM_ALL)
  endif()

  add_subdirectory(../../cpp cugraph-cpp ${_exclude_from_all})

  set(cython_lib_dir cugraph)
  install(TARGETS cugraph DESTINATION ${cython_lib_dir})
endif()

rapids_cython_init()

add_subdirectory(cugraph/centrality)
add_subdirectory(cugraph/community)
add_subdirectory(cugraph/components)
add_subdirectory(cugraph/dask/comms)
add_subdirectory(cugraph/dask/structure)
add_subdirectory(cugraph/generators)
add_subdirectory(cugraph/internals)
add_subdirectory(cugraph/layout)
add_subdirectory(cugraph/linear_assignment)
add_subdirectory(cugraph/link_prediction)
add_subdirectory(cugraph/structure)
add_subdirectory(cugraph/tree)
add_subdirectory(cugraph/utilities)

if(DEFINED cython_lib_dir)
  rapids_cython_add_rpath_entries(TARGET cugraph PATHS "${cython_lib_dir}")
endif()
