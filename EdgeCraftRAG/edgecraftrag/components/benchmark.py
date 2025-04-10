# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

import os
import threading
from typing import Any, List, Optional

import requests
from edgecraftrag.base import BaseComponent, CompType, InferenceType, ModelType
from prometheus_client.parser import text_string_to_metric_families
from pydantic import BaseModel, Field, model_serializer


class Benchmark(BaseComponent):

    def __init__(self, enable_benchmark, inference_type, tokenizer=None, bench_hook=None):
        super().__init__()
        self.enabled = enable_benchmark
        self.is_vllm = True if inference_type == InferenceType.VLLM else False

        self.tokenizer = tokenizer
        self.bench_hook = bench_hook

        self.benchmark_data_list = {}
        self.llm_data_list = {}

        self._idx_lock = threading.Lock()
        self.last_idx = 0
        self.dict_idx = 0

    def is_enabled(self):
        return self.enabled

    def enable(self):
        self.enabled = True

    def disable(self):
        self.enabled = False

    def cal_input_token_size(self, input_text_list):
        tokenizer = self.tokenizer
        if tokenizer:
            input_data = tokenizer(input_text_list, return_tensors="pt")
            input_data.pop("token_type_ids", None)
            input_tokens = input_data["input_ids"] if "input_ids" in input_data else input_data
            input_token_size = input_tokens[0].numel()
        else:
            input_token_size = -1
        return input_token_size

    def init_benchmark_data(self):
        pipeline_comp = [CompType.RETRIEVER, CompType.POSTPROCESSOR, CompType.GENERATOR]
        if self.is_enabled():
            with self._idx_lock:
                self.last_idx += 1
                idx = self.last_idx
            data = {}
            data["idx"] = idx
            for comp in pipeline_comp:
                data[comp] = ""
            return idx, data

    def update_benchmark_data(self, idx, comp_type, start, end):
        if self.is_enabled() and idx in self.benchmark_data_list and comp_type in self.benchmark_data_list[idx]:
            self.benchmark_data_list[idx][comp_type] = end - start

    def insert_benchmark_data(self, benchmark_data):
        idx = benchmark_data["idx"]
        self.benchmark_data_list[idx] = benchmark_data
        self.dict_idx = idx

    def insert_llm_data(self, idx, input_token_size):
        if self.is_enabled():
            if self.is_vllm:
                metrics = {}
                if input_token_size != -1:
                    metrics["input_token_size"] = input_token_size
                metrics = get_vllm_metrics(metrics)
            else:
                bench_hook = self.bench_hook
                if bench_hook:
                    metrics = {}
                    tm_list = bench_hook.get_time_list()
                    tm_infer_list = bench_hook.get_time_infer_list()
                    metrics["input_token_size"] = input_token_size
                    metrics["output_token_size"] = len(tm_list)
                    metrics["generation_time"] = sum(tm_list)
                    metrics["first_token_latency"] = tm_list[0] if len(tm_list) > 0 else ""
                    metrics["other_tokens_avg_latency"] = (
                        sum(tm_list[1:]) / len(tm_list[1:]) if len(tm_list) > 1 else ""
                    )
                    bench_hook.clear_time_list()
                    bench_hook.clear_time_infer_list()
                else:
                    metrics = None

            self.llm_data_list[idx] = metrics

    @model_serializer
    def ser_model(self):
        if self.enabled:
            set = {
                "Benchmark enabled": self.enabled,
                "last_benchmark_data": (
                    self.benchmark_data_list[self.dict_idx] if self.dict_idx in self.benchmark_data_list else None
                ),
                "llm_metrics": self.llm_data_list[self.dict_idx] if self.dict_idx in self.llm_data_list else None,
            }
        else:
            set = {
                "Benchmark enabled": self.enabled,
            }
        return set

    def run(self, **kwargs) -> Any:
        pass


def get_vllm_metrics(metrics):

    llm_endpoint = os.getenv("vLLM_ENDPOINT", "http://localhost:8008")
    response = requests.get(f"{llm_endpoint}/metrics", headers={"Content-Type": "application/json"})
    if response.status_code == 200:
        metrics_data = text_string_to_metric_families(response.text)
    else:
        return None

    parsed_metrics = {}
    for family in metrics_data:
        for sample in family.samples:
            parsed_metrics[sample.name] = sample

    vllm_metrics = [
        "vllm:prompt_tokens_total",
        "vllm:generation_tokens_total",
        "vllm:time_to_first_token_seconds_sum",
        "vllm:time_to_first_token_seconds_count",
        "vllm:time_per_output_token_seconds_sum",
        "vllm:time_per_output_token_seconds_count",
        "vllm:e2e_request_latency_seconds_sum",
        "vllm:e2e_request_latency_seconds_count",
    ]

    for metric in vllm_metrics:
        if metric in parsed_metrics:
            metrics[metric] = parsed_metrics[metric].value

    if "vllm:time_to_first_token_seconds_sum" in metrics and "vllm:time_to_first_token_seconds_count" in metrics:
        metrics["average_time_to_first_token_seconds"] = (
            metrics["vllm:time_to_first_token_seconds_sum"] / metrics["vllm:time_to_first_token_seconds_count"]
            if metrics["vllm:time_to_first_token_seconds_count"] > 0
            else None
        )
    if "vllm:time_per_output_token_seconds_sum" in metrics and "vllm:time_per_output_token_seconds_count" in metrics:
        metrics["average_time_per_output_token_seconds"] = (
            metrics["vllm:time_per_output_token_seconds_sum"] / metrics["vllm:time_per_output_token_seconds_count"]
            if metrics["vllm:time_per_output_token_seconds_count"] > 0
            else None
        )
    if "vllm:e2e_request_latency_seconds_sum" in metrics and "vllm:e2e_request_latency_seconds_count" in metrics:
        metrics["average_e2e_request_latency_seconds"] = (
            metrics["vllm:e2e_request_latency_seconds_sum"] / metrics["vllm:e2e_request_latency_seconds_count"]
            if metrics["vllm:e2e_request_latency_seconds_count"] > 0
            else None
        )

    return metrics
