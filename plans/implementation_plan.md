# Implementation Plan: Edge AI Infrastructure & Cost Controls on beby.cloud

This plan outlines the steps to recover and verify the edge NPU, implement Cozystack 1.4 GPU sharing, and set up a token-economical, real-time cost-controlled AI harness.

---

## Phase 1: Host-Level Driver & Recovery Post-Mortem

### The Crash Analysis
Forcing the `hailo_pci` driver built for Hailo-8 to bind to the Hailo-10H device (`1e60:45c4`) on `talos-428fe` resulted in a system-wide kernel panic, making the node offline (`NotReady` status, 100% packet loss).
**Reversal Strategy:**
1.  Power cycle the Raspberry Pi CM5 board.
2.  If the node is stuck in a boot loop, boot in Talos maintenance mode and remove the `hailo_pci` module from the configuration.
3.  **Correct Solution:** Instead of driver hacks, compile or obtain the newer `hailo1x_pci` kernel module containing native support for the Hailo-10H (`1e60:45c4`) device, or use a system extension built with HailoRT 4.18.0+.

---

## Phase 2: Cozystack 1.4 Fractional GPU Sharing (HAMi)

To share larger GPU resources dynamically across multiple teams and avoid "King of the Mountain" monopolization, we leverage Cozystack 1.4's new **HAMi** system package.

### Step 1: Install HAMi in Cozystack
Enable the `hami` system package in Cozystack value overlays to register fractional GPU resources:
*   Compute cores slice: `nvidia.com/gpucores` (percentage of GPU capacity, e.g. 50%)
*   Memory slice: `nvidia.com/gpumem` (memory size, e.g. 4096Mi or 4Gi)

### Step 2: Declare Fractional Resource Pods
Deploy tenant workloads that request only a fraction of the GPU:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: shared-inference-pod
  namespace: default
spec:
  containers:
  - name: vllm
    image: vllm/vllm-openai:latest
    resources:
      limits:
        nvidia.com/gpumem: "4Gi"     # Allocate exactly 4GB of GPU RAM
        nvidia.com/gpucores: "30"    # Allocate 30% of compute cores
```

---

## Phase 3: Building the ARM64 SDK Testing Image

For local testing when the NPU is recovered:
1.  **Dockerfile:** Setup Ubuntu base, install `hailort` arm64 Debian packages, and expose `hailortcli`.
2.  **Mounting /dev/hailo0:** Pods access the hardware via:
    ```yaml
    securityContext:
      privileged: true
    volumeMounts:
    - name: dev-hailo
      mountPath: /dev/hailo0
    ```

---

## Phase 4: Model Quantization for Hailo-10H

To run models under the node's 8GB system memory constraint, we convert standard models into HEF (Hailo Executable Format):
1.  Convert the model weights (e.g. Qwen-2.5-1.5B) to ONNX.
2.  Use the **Hailo Dataflow Compiler (DFC)** to quantize parameters to 8-bit/4-bit integers.
3.  Compile to a `.hef` file optimized for the Hailo-10H NPU architecture.

---

## Phase 5: LiteLLM, Open WebUI, and Real-Time Quota Controls

To provide a competitive user experience with immediate cost feedback (unlike Copilot's 1-hour delay):

```
[Open WebUI] ---> [Custom Cost-Accounting Proxy] ---> [LiteLLM] ---> [Groq / OpenRouter]
                      (Real-Time Quota Tracking)
```

### Step 1: Deploy Open WebUI & LiteLLM
1.  Utilize `gpt.beby.cloud` for Open WebUI admin-mode prototyping.
2.  Deploy LiteLLM inside the cluster to handle query routing.
3.  Configure LiteLLM with fallback backends: local NPU for small queries, and external APIs (Groq, OpenRouter) for heavy frontier models.

### Step 2: Implement Real-Time Cost Accounting & Pacing Alerts
1.  **Cost-Accounting Hook:** Insert a lightweight middleware proxy between Open WebUI and LiteLLM.
2.  **Streaming Token Estimator:** As LLM responses stream, the proxy calculates the exact cost in real-time based on input/output token counts.
3.  **Real-Time Quota Tracking & Daily Pacing System:**
    - The proxy tracks the user's monthly and daily targets (e.g. daily pacing limit to prevent exhausting the budget on day one).
    - It reports usage with sub-second latency immediately after every request, rendering a visual progress gauge (similar to the legacy Gemini Code quota meter) directly in the UI.
    - If daily usage rate outpaces the target daily fraction (e.g. exceeding 3.3% in a single day, indicating rapid exhaustion), it injects an immediate warning/inline notification to alert the user to pace their usage.

### Step 3: RTK & Caveman Token Savers
1.  **RTK (Rust Token Killer):** Compresses CLI/shell outputs by 60–90% before forwarding them to the LLM.
2.  **Caveman Skill:** Prompting rule that strips natural language filler to ensure output is dense and token-efficient.
