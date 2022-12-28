/*
 * Copyright (c) 2020-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <community/detail/common_methods.hpp>

#include <community/detail/mis.hpp>

#include <detail/graph_utils.cuh>
#include <prims/per_v_transform_reduce_dst_key_aggregated_outgoing_e.cuh>
#include <prims/per_v_transform_reduce_incoming_outgoing_e.cuh>
#include <prims/reduce_op.cuh>
#include <prims/transform_reduce_e.cuh>
#include <prims/transform_reduce_e_by_src_dst_key.cuh>
#include <prims/update_edge_src_dst_property.cuh>
#include <utilities/collect_comm.cuh>

#include <cugraph/detail/utility_wrappers.hpp>
#include <cugraph/graph_functions.hpp>

#include <thrust/binary_search.h>
#include <thrust/distance.h>
#include <thrust/execution_policy.h>
#include <thrust/functional.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/optional.h>
#include <thrust/sequence.h>
#include <thrust/shuffle.h>
#include <thrust/sort.h>
#include <thrust/tabulate.h>
#include <thrust/transform.h>
#include <thrust/transform_reduce.h>
#include <thrust/tuple.h>

CUCO_DECLARE_BITWISE_COMPARABLE(float)
CUCO_DECLARE_BITWISE_COMPARABLE(double)

namespace cugraph {
namespace detail {

// a workaround for cudaErrorInvalidDeviceFunction error when device lambda is used
template <typename vertex_t, typename weight_t>
struct reduce_op_t {
  using type                          = thrust::tuple<vertex_t, weight_t>;
  static constexpr bool pure_function = true;  // this can be called from any process
  // inline static type const identity_element =
  //   thrust::make_tuple(std::numeric_limits<weight_t>::lowest(),
  //   invalid_vertex_id<vertex_t>::value);

  __device__ auto operator()(thrust::tuple<vertex_t, weight_t> p0,
                             thrust::tuple<vertex_t, weight_t> p1) const
  {
    auto id0 = thrust::get<0>(p0);
    auto id1 = thrust::get<0>(p1);
    auto wt0 = thrust::get<1>(p0);
    auto wt1 = thrust::get<1>(p1);

    return (wt0 < wt1) ? p1 : ((wt0 > wt1) ? p0 : ((id0 < id1) ? p0 : p1));
  }
};

// a workaround for cudaErrorInvalidDeviceFunction error when device lambda is used
template <typename vertex_t, typename weight_t, typename cluster_value_t>
struct leiden_key_aggregated_edge_op_t {
  weight_t total_edge_weight{};
  weight_t resolution{};
  weight_t gamma{};
  __device__ auto operator()(
    vertex_t src,
    vertex_t neighboring_leiden_cluster,
    thrust::tuple<weight_t, weight_t, weight_t, uint8_t, vertex_t, vertex_t> src_info,
    cluster_value_t keyed_data,
    weight_t aggregated_weight_to_neighboring_leiden_cluster) const
  {
    // Data associated with src vertex
    auto src_weighted_deg          = thrust::get<0>(src_info);
    auto src_vertex_cut_to_louvain = thrust::get<1>(src_info);
    auto louvain_cluster_volume    = thrust::get<2>(src_info);
    auto src_singleton_flag        = thrust::get<3>(src_info);
    auto src_leiden_cluster        = thrust::get<4>(src_info);
    auto src_louvain_cluster       = thrust::get<5>(src_info);

    // Data associated with target leiden (aka refined) cluster

    auto dst_leiden_volume             = thrust::get<0>(keyed_data);
    auto dst_leiden_cut_to_louvain     = thrust::get<1>(keyed_data);
    auto dst_leiden_cluster_id         = thrust::get<2>(keyed_data);
    auto louvain_of_dst_leiden_cluster = thrust::get<3>(keyed_data);

    // neighboring_leiden_cluster and dst_leiden_cluster_id must have same value

    // TODO: This is check can be done in outer scope
    // pass it as parameter
    // E(v, S-v) > ||v||*(||S|| -||v||)
    bool is_src_well_connected =
      src_vertex_cut_to_louvain >
      gamma * src_weighted_deg * (louvain_cluster_volume - src_weighted_deg);

    // E(Cr, S-Cr) > ||Cr||*(||S|| -||Cr||)
    bool is_dst_leiden_cluster_well_connected =
      dst_leiden_cut_to_louvain >
      gamma * dst_leiden_volume * (louvain_cluster_volume - dst_leiden_volume);

    // E(v, Cr-v) - ||v||* ||Cr-v||/||V(G)||
    // aggregated_weight_to_neighboring_leiden_cluster == E(v, Cr-v)?

    weight_t theta = -1.0;

    // avoid self loop should
    if ((src_leiden_cluster != dst_leiden_cluster_id) && src_singleton_flag &&
        is_src_well_connected) {
      if (louvain_of_dst_leiden_cluster == src_louvain_cluster &&
          is_dst_leiden_cluster_well_connected) {
        theta = aggregated_weight_to_neighboring_leiden_cluster -
                src_weighted_deg * dst_leiden_volume / total_edge_weight;
      }
    }

    return thrust::make_tuple(neighboring_leiden_cluster, theta);
  }
};

//
// Construct Leiden to Louvain mapping
//
template <typename vertex_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<vertex_t>>
build_leiden_to_louvain_map(raft::handle_t const& handle,
                            rmm::device_uvector<vertex_t>& leiden_assignment,
                            rmm::device_uvector<vertex_t>& louvain_assignment)
{
  rmm::device_uvector<vertex_t> keys_of_leiden_to_louvain_map(leiden_assignment.size(),
                                                              handle.get_stream());
  rmm::device_uvector<vertex_t> values_of_leiden_to_louvain_map(louvain_assignment.size(),
                                                                handle.get_stream());

  thrust::copy(handle.get_thrust_policy(),
               leiden_assignment.begin(),
               leiden_assignment.end(),
               keys_of_leiden_to_louvain_map.begin());

  thrust::copy(handle.get_thrust_policy(),
               louvain_assignment.begin(),
               louvain_assignment.end(),
               values_of_leiden_to_louvain_map.begin());

  auto louvain_leiden_zipped_begin = thrust::make_zip_iterator(thrust::make_tuple(
    values_of_leiden_to_louvain_map.begin(), keys_of_leiden_to_louvain_map.begin()));

  auto louvain_leiden_zipped_end = thrust::make_zip_iterator(
    thrust::make_tuple(values_of_leiden_to_louvain_map.end(), keys_of_leiden_to_louvain_map.end()));

  thrust::sort(handle.get_thrust_policy(),
               louvain_leiden_zipped_begin,
               louvain_leiden_zipped_end,
               thrust::less<thrust::tuple<vertex_t, vertex_t>>());

  auto last_unique_louvain_leiden_pair =
    thrust::unique(handle.get_thrust_policy(),
                   louvain_leiden_zipped_begin,
                   louvain_leiden_zipped_end,
                   thrust::less<thrust::tuple<vertex_t, vertex_t>>());

  auto nr_unique_louvain_leiden_pairs = static_cast<size_t>(
    thrust::distance(louvain_leiden_zipped_begin, last_unique_louvain_leiden_pair));

  keys_of_leiden_to_louvain_map.resize(nr_unique_louvain_leiden_pairs, handle.get_stream());
  values_of_leiden_to_louvain_map.resize(nr_unique_louvain_leiden_pairs, handle.get_stream());

  return std::make_tuple(std::move(keys_of_leiden_to_louvain_map),
                         std::move(values_of_leiden_to_louvain_map));
}

template <typename GraphViewType, typename weight_t>
std::tuple<rmm::device_uvector<typename GraphViewType::vertex_type>,
           std::pair<rmm::device_uvector<typename GraphViewType::vertex_type>,
                     rmm::device_uvector<typename GraphViewType::vertex_type>>>
refine_clustering(
  raft::handle_t const& handle,
  GraphViewType const& graph_view,
  std::optional<edge_property_view_t<typename GraphViewType::edge_type, weight_t const*>>
    edge_weight_view,
  weight_t total_edge_weight,
  weight_t resolution,
  rmm::device_uvector<weight_t> const& vertex_weights_v,
  rmm::device_uvector<typename GraphViewType::vertex_type>&& cluster_keys_v,
  rmm::device_uvector<weight_t>&& cluster_weights_v,
  rmm::device_uvector<typename GraphViewType::vertex_type>&& louvain_assignment,
  edge_src_property_t<GraphViewType, weight_t> const& src_vertex_weights_cache,
  edge_src_property_t<GraphViewType, typename GraphViewType::vertex_type> const&
    src_louvain_assignment,
  edge_dst_property_t<GraphViewType, typename GraphViewType::vertex_type> const&
    dst_louvain_assignment,
  bool up_down)
{
  using vertex_t = typename GraphViewType::vertex_type;
  using edge_t   = typename GraphViewType::edge_type;

  rmm::device_uvector<weight_t> vertex_cluster_weights_v =
    lookup_primitive_values_for_keys<vertex_t, weight_t, GraphViewType::is_multi_gpu>(
      handle, cluster_keys_v, cluster_weights_v, louvain_assignment);

  //
  // For each vertex, compute its weighted degree (||v||)
  // and cut between itself and its Louvain community (E(v, S-v))
  //

  rmm::device_uvector<weight_t> weighted_degree_of_vertices(
    graph_view.local_vertex_partition_range_size(), handle.get_stream());

  rmm::device_uvector<weight_t> weighted_cut_of_vertices_to_louvain(
    graph_view.local_vertex_partition_range_size(), handle.get_stream());

  per_v_transform_reduce_outgoing_e(
    handle,
    graph_view,
    GraphViewType::is_multi_gpu
      ? src_louvain_assignment.view()
      : detail::edge_major_property_view_t<vertex_t, vertex_t const*>(louvain_assignment.data()),
    GraphViewType::is_multi_gpu ? dst_louvain_assignment.view()
                                : detail::edge_minor_property_view_t<vertex_t, vertex_t const*>(
                                    louvain_assignment.data(), vertex_t{0}),
    *edge_weight_view,
    [] __device__(auto src, auto dst, auto src_cluster, auto dst_cluster, auto wt) {
      weight_t weighted_deg_contribution{wt};
      weight_t weighted_cut_contribution{0};

      if (src == dst)  // self loop
        weighted_cut_contribution = 0;
      else if (src_cluster == dst_cluster)
        weighted_cut_contribution = wt;

      return thrust::make_tuple(weighted_deg_contribution, weighted_cut_contribution);
    },
    thrust::make_tuple(weight_t{0}, weight_t{0}),
    thrust::make_zip_iterator(thrust::make_tuple(weighted_degree_of_vertices.begin(),
                                                 weighted_cut_of_vertices_to_louvain.begin())));

  rmm::device_uvector<uint8_t> is_vertex_well_connected_in_louvain(
    graph_view.local_vertex_partition_range_size(), handle.get_stream());

  thrust::fill(handle.get_thrust_policy(),
               is_vertex_well_connected_in_louvain.begin(),
               is_vertex_well_connected_in_louvain.end(),
               uint8_t{0});

  weight_t gamma = 1.0 / 7.0;

  auto w_cut_deg_and_cluster_volume_begin =
    thrust::make_zip_iterator(thrust::make_tuple(weighted_cut_of_vertices_to_louvain.begin(),
                                                 weighted_degree_of_vertices.begin(),
                                                 vertex_cluster_weights_v.begin()));
  auto w_cut_deg_and_cluster_volume_end =
    thrust::make_zip_iterator(thrust::make_tuple(weighted_cut_of_vertices_to_louvain.end(),
                                                 weighted_degree_of_vertices.end(),
                                                 vertex_cluster_weights_v.end()));

  thrust::transform(handle.get_thrust_policy(),
                    w_cut_deg_and_cluster_volume_begin,
                    w_cut_deg_and_cluster_volume_end,
                    is_vertex_well_connected_in_louvain.begin(),
                    [gamma = gamma] __device__(auto wcut_wdeg_and_louvain_volume) {
                      auto wcut           = thrust::get<0>(wcut_wdeg_and_louvain_volume);
                      auto wdeg           = thrust::get<1>(wcut_wdeg_and_louvain_volume);
                      auto louvain_volume = thrust::get<2>(wcut_wdeg_and_louvain_volume);
                      return wcut > (gamma * wdeg * (louvain_volume - wdeg));
                    });

  // Update cluster weight, weighted degree and cut for edge sources

  edge_src_property_t<GraphViewType, weight_t> src_louvain_cluster_weights(handle);
  edge_src_property_t<GraphViewType, thrust::tuple<weight_t, weight_t>> src_wdeg_and_cut_to_Louvain(
    handle);
  edge_src_property_t<GraphViewType, weight_t> src_cut_to_Leiden(handle);

  if (GraphViewType::is_multi_gpu) {
    src_louvain_cluster_weights = edge_src_property_t<GraphViewType, weight_t>(handle, graph_view);
    update_edge_src_property(
      handle, graph_view, vertex_cluster_weights_v.begin(), src_louvain_cluster_weights);

    src_wdeg_and_cut_to_Louvain =
      edge_src_property_t<GraphViewType, thrust::tuple<weight_t, weight_t>>(handle, graph_view);
    update_edge_src_property(
      handle,
      graph_view,
      thrust::make_zip_iterator(thrust::make_tuple(weighted_degree_of_vertices.begin(),
                                                   weighted_cut_of_vertices_to_louvain.begin())),
      src_wdeg_and_cut_to_Louvain);

    src_cut_to_Leiden = edge_src_property_t<GraphViewType, weight_t>(handle, graph_view);

    vertex_cluster_weights_v.resize(0, handle.get_stream());
    vertex_cluster_weights_v.shrink_to_fit(handle.get_stream());

    weighted_degree_of_vertices.resize(0, handle.get_stream());
    weighted_degree_of_vertices.shrink_to_fit(handle.get_stream());

    weighted_cut_of_vertices_to_louvain.resize(0, handle.get_stream());
    weighted_cut_of_vertices_to_louvain.shrink_to_fit(handle.get_stream());
  }

  //
  // Assign Lieden community Id for vertices.
  // Each vertex starts as a singleton community in the leiden partition
  //

  rmm::device_uvector<vertex_t> leiden_assignment = rmm::device_uvector<vertex_t>(
    graph_view.local_vertex_partition_range_size(), handle.get_stream());

  detail::sequence_fill(handle.get_stream(),
                        leiden_assignment.begin(),
                        leiden_assignment.size(),
                        graph_view.local_vertex_partition_range_first());

  //
  // Mask to indicate if a vertex is singleton
  //

  rmm::device_uvector<uint8_t> singleton_flags(leiden_assignment.size(), handle.get_stream());
  thrust::fill(
    handle.get_thrust_policy(), singleton_flags.begin(), singleton_flags.end(), uint8_t{1});

  edge_src_property_t<GraphViewType, vertex_t> src_leiden_assignment(handle);
  edge_dst_property_t<GraphViewType, vertex_t> dst_leiden_assignment(handle);
  edge_src_property_t<GraphViewType, uint8_t> src_singleton_mask(handle);

  if constexpr (GraphViewType::is_multi_gpu) {
    src_leiden_assignment = edge_src_property_t<GraphViewType, vertex_t>(handle, graph_view);
    dst_leiden_assignment = edge_dst_property_t<GraphViewType, vertex_t>(handle, graph_view);
    src_singleton_mask    = edge_src_property_t<GraphViewType, uint8_t>(handle, graph_view);
  }

  rmm::device_uvector<vertex_t> keys_of_leiden_to_louvain_map(0, handle.get_stream());
  rmm::device_uvector<vertex_t> values_of_leiden_to_louvain_map(0, handle.get_stream());

  while (true) {
    rmm::device_uvector<uint8_t> yet_to_consider(graph_view.local_vertex_partition_range_size(),
                                                 handle.get_stream());
    thrust::transform(
      handle.get_thrust_policy(),
      singleton_flags.begin(),
      singleton_flags.end(),
      is_vertex_well_connected_in_louvain.begin(),
      yet_to_consider.begin(),
      [] __device__(auto singleton, auto well_connected) { return singleton && well_connected; });

    vertex_t remaining_vertices_to_consider =
      thrust::reduce(handle.get_thrust_policy(), yet_to_consider.begin(), yet_to_consider.end());

    if (GraphViewType::is_multi_gpu) {
      remaining_vertices_to_consider = host_scalar_allreduce(handle.get_comms(),
                                                             remaining_vertices_to_consider,
                                                             raft::comms::op_t::SUM,
                                                             handle.get_stream());
    }
    if (remaining_vertices_to_consider == 0) { break; }

    // Update Leiden assignment to edge sources and destinitions
    // and singleton mask to edge sources
    if constexpr (GraphViewType::is_multi_gpu) {
      update_edge_src_property(
        handle, graph_view, leiden_assignment.begin(), src_leiden_assignment);

      update_edge_dst_property(
        handle, graph_view, leiden_assignment.begin(), dst_leiden_assignment);

      update_edge_src_property(handle, graph_view, singleton_flags.begin(), src_singleton_mask);
    }

    auto src_input_property_values =
      GraphViewType::is_multi_gpu
        ? view_concat(src_louvain_assignment.view(), src_leiden_assignment.view())
        : view_concat(detail::edge_major_property_view_t<vertex_t, vertex_t const*>(
                        louvain_assignment.data()),
                      detail::edge_major_property_view_t<vertex_t, vertex_t const*>(
                        leiden_assignment.data()));

    auto dst_input_property_values =
      GraphViewType::is_multi_gpu
        ? view_concat(dst_louvain_assignment.view(), dst_leiden_assignment.view())
        : view_concat(detail::edge_minor_property_view_t<vertex_t, vertex_t const*>(
                        louvain_assignment.data(), vertex_t{0}),
                      detail::edge_minor_property_view_t<vertex_t, vertex_t const*>(
                        leiden_assignment.data(), vertex_t{0}));

    rmm::device_uvector<vertex_t> leiden_keys_used_in_edge_reduction(0, handle.get_stream());
    rmm::device_uvector<weight_t> refined_community_volumes(0, handle.get_stream());
    rmm::device_uvector<weight_t> refined_community_cuts(0, handle.get_stream());

    //
    // For each refined community, compute its volume
    // (i.e.sum of weighted degree of all vertices inside it, ||Cr||) and
    // and cut between itself and its Louvain community (E(Cr, S-Cr))
    //
    // TODO: Can you update ||Cr|| and E(Cr, S-Cr) instead of recomputing?

    std::forward_as_tuple(leiden_keys_used_in_edge_reduction,
                          std::tie(refined_community_volumes, refined_community_cuts)) =
      cugraph::transform_reduce_e_by_dst_key(
        handle,
        graph_view,
        src_input_property_values,
        dst_input_property_values,
        *edge_weight_view,
        GraphViewType::is_multi_gpu ? dst_leiden_assignment.view()
                                    : detail::edge_minor_property_view_t<vertex_t, vertex_t const*>(
                                        leiden_assignment.data(), vertex_t{0}),

        [] __device__(auto src,
                      auto dst,
                      thrust::tuple<vertex_t, vertex_t> src_louvain_leidn,
                      thrust::tuple<vertex_t, vertex_t> dst_louvain_leiden,
                      auto wt) {
          weight_t refined_partition_volume_contribution{0};
          weight_t refined_partition_cut_contribution{0};

          auto src_louvain = thrust::get<0>(src_louvain_leidn);
          auto src_leiden  = thrust::get<1>(src_louvain_leidn);

          auto dst_louvain = thrust::get<0>(dst_louvain_leiden);
          auto dst_leiden  = thrust::get<1>(dst_louvain_leiden);

          // if (src == dst) {
          //   refined_partition_volume_contribution = wt;
          // } else

          if (src_louvain == dst_louvain) {
            if (src_leiden == dst_leiden) {
              refined_partition_volume_contribution = wt;
            } else {
              refined_partition_cut_contribution = wt;
            }
          }
          return thrust::make_tuple(refined_partition_volume_contribution,
                                    refined_partition_cut_contribution);
        },
        thrust::make_tuple(weight_t{0}, weight_t{0}),
        reduce_op::plus<thrust::tuple<weight_t, weight_t>>{});

    //
    // Primitives to decide best (at least good) next clusters for vertices
    //

    // ||v||
    // E(v, louvain(v))
    // ||louvain(v)||
    // is_singleton(v)
    // leiden(v)
    // louvain(v)

    auto zipped_src_device_view =
      GraphViewType::is_multi_gpu
        ? view_concat(src_wdeg_and_cut_to_Louvain.view(),
                      src_louvain_cluster_weights.view(),
                      src_singleton_mask.view(),
                      src_leiden_assignment.view(),
                      src_louvain_assignment.view())
        : view_concat(
            detail::edge_major_property_view_t<vertex_t, weight_t const*>(
              weighted_degree_of_vertices.data()),
            detail::edge_major_property_view_t<vertex_t, weight_t const*>(
              weighted_cut_of_vertices_to_louvain.data()),
            detail::edge_major_property_view_t<vertex_t, weight_t const*>(
              vertex_cluster_weights_v.data()),
            detail::edge_major_property_view_t<vertex_t, uint8_t const*>(singleton_flags.data()),
            detail::edge_major_property_view_t<vertex_t, vertex_t const*>(leiden_assignment.data()),
            detail::edge_major_property_view_t<vertex_t, vertex_t const*>(
              louvain_assignment.data()));

    std::tie(keys_of_leiden_to_louvain_map, values_of_leiden_to_louvain_map) =
      build_leiden_to_louvain_map<vertex_t, GraphViewType::is_multi_gpu>(
        handle, leiden_assignment, louvain_assignment);

    auto louvain_of_edge_reduced_leiden_keys =
      lookup_primitive_values_for_keys<vertex_t, vertex_t, GraphViewType::is_multi_gpu>(
        handle,
        keys_of_leiden_to_louvain_map,
        values_of_leiden_to_louvain_map,
        leiden_keys_used_in_edge_reduction);

    // ||Cr|| //f(Cr)
    // E(Cr, louvain(v) - Cr) //f(Cr)
    // leiden(Cr) // f(Cr)
    // louvain(Cr) // f(Cr)
    auto values_for_leiden_cluster_keys = thrust::make_zip_iterator(
      thrust::make_tuple(refined_community_volumes.begin(),
                         refined_community_cuts.begin(),
                         leiden_keys_used_in_edge_reduction.begin(),  // redundant
                         louvain_of_edge_reduced_leiden_keys.begin()));

    using value_t = thrust::tuple<weight_t, weight_t, vertex_t, vertex_t>;
    kv_store_t<vertex_t, value_t, true> leiden_cluster_key_values_map(
      leiden_keys_used_in_edge_reduction.begin(),
      leiden_keys_used_in_edge_reduction.begin() + leiden_keys_used_in_edge_reduction.size(),
      values_for_leiden_cluster_keys,
      thrust::make_tuple(std::numeric_limits<weight_t>::max(),
                         std::numeric_limits<weight_t>::max(),
                         invalid_vertex_id<vertex_t>::value,
                         invalid_vertex_id<vertex_t>::value),
      false,
      handle.get_stream());

    //
    // Decide best/positive move for each vertex
    //

    auto target_and_gain_output_pairs =
      allocate_dataframe_buffer<thrust::tuple<vertex_t, weight_t>>(
        graph_view.local_vertex_partition_range_size(), handle.get_stream());

    per_v_transform_reduce_dst_key_aggregated_outgoing_e(
      handle,
      graph_view,
      zipped_src_device_view,
      *edge_weight_view,
      GraphViewType::is_multi_gpu ? dst_leiden_assignment.view()
                                  : detail::edge_minor_property_view_t<vertex_t, vertex_t const*>(
                                      leiden_assignment.data(), vertex_t{0}),
      leiden_cluster_key_values_map.view(),
      detail::leiden_key_aggregated_edge_op_t<vertex_t, weight_t, value_t>{
        total_edge_weight, resolution, gamma},
      thrust::make_tuple(vertex_t{-1}, weight_t{0}),
      detail::reduce_op_t<vertex_t, weight_t>{},
      cugraph::get_dataframe_buffer_begin(target_and_gain_output_pairs));

    //
    // Create edgelist from (source, target community, modulraity gain) tuple
    //

    size_t num_vertices = graph_view.local_vertex_partition_range_size();
    rmm::device_uvector<vertex_t> d_srcs(num_vertices, handle.get_stream());
    rmm::device_uvector<vertex_t> d_dsts(num_vertices, handle.get_stream());
    std::optional<rmm::device_uvector<weight_t>> d_weights =
      std::make_optional(rmm::device_uvector<weight_t>(num_vertices, handle.get_stream()));

    auto d_src_dst_gain_iterator = thrust::make_zip_iterator(
      thrust::make_tuple(d_srcs.begin(), d_dsts.begin(), (*d_weights).begin()));

    auto vertex_begin =
      thrust::make_counting_iterator(graph_view.local_vertex_partition_range_first());
    auto vertex_end =
      thrust::make_counting_iterator(graph_view.local_vertex_partition_range_last());

    auto dst_and_gain_first = get_dataframe_buffer_cbegin(target_and_gain_output_pairs);
    auto edge_begin         = thrust::make_zip_iterator(
      thrust::make_tuple(vertex_begin,
                         thrust::get<0>(dst_and_gain_first.get_iterator_tuple()),
                         thrust::get<1>(dst_and_gain_first.get_iterator_tuple())));

    auto dst_and_gain_last = cugraph::get_dataframe_buffer_cend(target_and_gain_output_pairs);
    auto edge_end          = thrust::make_zip_iterator(
      thrust::make_tuple(vertex_end,
                         thrust::get<0>(dst_and_gain_last.get_iterator_tuple()),
                         thrust::get<1>(dst_and_gain_last.get_iterator_tuple())));

    //
    // Filter out moves with -ve gains
    //
    thrust::copy_if(handle.get_thrust_policy(),
                    edge_begin,
                    edge_end,
                    d_src_dst_gain_iterator,
                    [] __device__(thrust::tuple<vertex_t, vertex_t, weight_t> src_dst_gain) {
                      return (thrust::get<2>(src_dst_gain)) > 0.0;
                    });

    //
    // Create decision graph from edgelist
    //
    constexpr bool storage_transposed = false;
    constexpr bool multi_gpu          = GraphViewType::is_multi_gpu;
    using DecisionGraphViewType       = cugraph::graph_view_t<vertex_t, edge_t, false, multi_gpu>;

    cugraph::graph_t<vertex_t, edge_t, storage_transposed, multi_gpu> decision_graph(handle);

    std::optional<rmm::device_uvector<vertex_t>> renumber_map{std::nullopt};
    std::optional<edge_property_t<DecisionGraphViewType, weight_t>> coarse_edge_weights{
      std::nullopt};

    rmm::device_uvector<vertex_t> copied_srcs(leiden_assignment.size(), handle.get_stream());
    rmm::device_uvector<vertex_t> copied_dsts(leiden_assignment.size(), handle.get_stream());

    thrust::copy(handle.get_thrust_policy(), d_srcs.begin(), d_srcs.end(), copied_srcs.begin());

    thrust::copy(handle.get_thrust_policy(), d_dsts.begin(), d_dsts.end(), copied_dsts.begin());

    std::tie(decision_graph, coarse_edge_weights, std::ignore, renumber_map) =
      create_graph_from_edgelist<vertex_t,
                                 edge_t,
                                 weight_t,
                                 int32_t,
                                 storage_transposed,
                                 multi_gpu>(handle,
                                            std::nullopt,
                                            std::move(d_srcs),
                                            std::move(d_dsts),
                                            std::move(d_weights),
                                            std::nullopt,
                                            cugraph::graph_properties_t{false, false},
                                            multi_gpu ? true : false);

    auto decision_graph_view = decision_graph.view();

    //
    // Determine a set of moves using MIS of the decision_graph
    //

    auto chosen_nodes = compute_mis<vertex_t, edge_t, weight_t, multi_gpu>(
      handle,
      decision_graph_view,
      coarse_edge_weights ? std::make_optional(coarse_edge_weights->view()) : std::nullopt);

    rmm::device_uvector<vertex_t> numbering_indices((*renumber_map).size(), handle.get_stream());
    detail::sequence_fill(handle.get_stream(),
                          numbering_indices.data(),
                          numbering_indices.size(),
                          decision_graph_view.local_vertex_partition_range_first());

    //
    // Apply Renumber map to get original node ids
    //
    relabel<vertex_t, multi_gpu>(
      handle,
      std::make_tuple(static_cast<vertex_t const*>((*renumber_map).begin()),
                      static_cast<vertex_t const*>(numbering_indices.begin())),
      decision_graph_view.local_vertex_partition_range_size(),
      chosen_nodes.data(),
      chosen_nodes.size(),
      false);

    //
    // Move chosen leiden communities to their targets
    //

    // Flags to indicate nodes that are chosen by MIS

    thrust::sort(handle.get_thrust_policy(), chosen_nodes.begin(), chosen_nodes.end());
    rmm::device_uvector<uint8_t> flags_move(leiden_assignment.size(), handle.get_stream());

    thrust::transform(
      handle.get_thrust_policy(),
      vertex_begin,
      vertex_end,
      flags_move.begin(),
      [d_nodes_to_move   = chosen_nodes.data(),
       num_nodes_to_move = chosen_nodes.size()] __device__(vertex_t id_to_lookup) {
        return thrust::binary_search(
          thrust::seq, d_nodes_to_move, d_nodes_to_move + num_nodes_to_move, id_to_lookup);
      });

    // Nodes that are moving become non-singleton

    thrust::transform(
      handle.get_thrust_policy(),
      flags_move.begin(),
      flags_move.end(),
      singleton_flags.begin(),
      singleton_flags.begin(),
      [] __device__(auto is_moving, auto current_mask) { return (!is_moving && current_mask); });

    // Gather all dest comms

    rmm::device_uvector<vertex_t> target_comms(
      decision_graph_view.local_vertex_partition_range_size(), handle.get_stream());

    target_comms.resize(static_cast<size_t>(thrust::distance(
                          thrust::copy_if(handle.get_thrust_policy(),
                                          thrust::get<0>(dst_and_gain_first.get_iterator_tuple()),
                                          thrust::get<0>(dst_and_gain_last.get_iterator_tuple()),
                                          flags_move.begin(),
                                          target_comms.begin(),
                                          [] __device__(auto is_moving) { return is_moving; }),
                          target_comms.begin())),
                        handle.get_stream());

    thrust::sort(handle.get_thrust_policy(), target_comms.begin(), target_comms.end());

    target_comms.resize(
      static_cast<size_t>(thrust::distance(
        target_comms.begin(),
        thrust::unique(handle.get_thrust_policy(), target_comms.begin(), target_comms.end()))),
      handle.get_stream());

    if constexpr (GraphViewType::is_multi_gpu) {
      target_comms = shuffle_int_vertices_by_gpu_id(
        handle, std::move(target_comms), graph_view.vertex_partition_range_lasts());

      thrust::sort(handle.get_thrust_policy(), target_comms.begin(), target_comms.end());

      target_comms.resize(static_cast<size_t>(thrust::distance(
        target_comms.begin(),
        thrust::unique(handle.get_thrust_policy(), target_comms.begin(), target_comms.end()))));
    }

    // Makr all the dest comms as non-sigleton

    rmm::device_uvector<uint8_t> flags_dest(leiden_assignment.size(), handle.get_stream());

    thrust::transform(handle.get_thrust_policy(),
                      vertex_begin,
                      vertex_end,
                      flags_dest.begin(),
                      [dests     = target_comms.data(),
                       num_dests = target_comms.size()] __device__(vertex_t target_id) {
                        return thrust::binary_search(
                          thrust::seq, dests, dests + num_dests, target_id);
                      });

    thrust::transform(
      handle.get_thrust_policy(),
      flags_dest.begin(),
      flags_dest.end(),
      singleton_flags.begin(),
      singleton_flags.begin(),
      [] __device__(auto is_dest, auto current_mask) { return (!is_dest && current_mask); });

    // Update leiden assignment for the nodes that are moving

    thrust::transform_if(
      handle.get_thrust_policy(),
      leiden_assignment.begin(),
      leiden_assignment.end(),
      thrust::get<0>(dst_and_gain_first.get_iterator_tuple()),
      flags_move.begin(),
      leiden_assignment.begin(),
      [] __device__(auto, vertex_t target_leiden_comm) { return target_leiden_comm; },
      thrust::identity<vertex_t>());
  }

  //
  // Re-read Leiden to Louvain map, but for remaining (after moving) Leiden communities
  //
  rmm::device_uvector<vertex_t> leiden_keys_to_read_louvain(leiden_assignment.size(),
                                                            handle.get_stream());

  thrust::copy(handle.get_thrust_policy(),
               leiden_assignment.begin(),
               leiden_assignment.end(),
               leiden_keys_to_read_louvain.begin());

  thrust::sort(handle.get_thrust_policy(),
               leiden_keys_to_read_louvain.begin(),
               leiden_keys_to_read_louvain.end());
  auto nr_unique_leiden_clusters =
    static_cast<size_t>(thrust::distance(leiden_keys_to_read_louvain.begin(),
                                         thrust::unique(handle.get_thrust_policy(),
                                                        leiden_keys_to_read_louvain.begin(),
                                                        leiden_keys_to_read_louvain.end())));

  if constexpr (GraphViewType::is_multi_gpu) {
    leiden_keys_to_read_louvain =
      shuffle_ext_vertices_by_gpu_id(handle, std::move(leiden_keys_to_read_louvain));

    thrust::sort(handle.get_thrust_policy(),
                 leiden_keys_to_read_louvain.begin(),
                 leiden_keys_to_read_louvain.end());

    nr_unique_leiden_clusters =
      static_cast<size_t>(thrust::distance(leiden_keys_to_read_louvain.begin(),
                                           thrust::unique(handle.get_thrust_policy(),
                                                          leiden_keys_to_read_louvain.begin(),
                                                          leiden_keys_to_read_louvain.end())));
  }

  leiden_keys_to_read_louvain.resize(nr_unique_leiden_clusters, handle.get_stream());

  auto lovain_of_leiden_cluster_keys =
    lookup_primitive_values_for_keys<vertex_t, vertex_t, GraphViewType::is_multi_gpu>(
      handle,
      keys_of_leiden_to_louvain_map,
      values_of_leiden_to_louvain_map,
      leiden_keys_to_read_louvain);

  return std::make_tuple(std::move(leiden_assignment),
                         std::make_pair(std::move(leiden_keys_to_read_louvain),
                                        std::move(lovain_of_leiden_cluster_keys)));
}
}  // namespace detail
}  // namespace cugraph