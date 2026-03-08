(() => {
  const messageHandler = window.webkit?.messageHandlers?.autoPresenterBridge;

  const state = {
    pc: null,
    dc: null,
    localStream: null,
    manual: {
      commitIntervalMs: 260,
      commitTimer: null,
      monitorTimer: null,
      audioContext: null,
      sourceNode: null,
      analyser: null,
      analyserData: null,
      speechActive: false,
      speechStartedAt: 0,
      lastSpeechAt: 0,
      speechTailMs: 260,
      minSpeechLeadMs: 140,
      rmsThreshold: 0.006,
      pendingResponse: false,
      pendingSince: 0,
      responseTimeoutMs: 5000,
      maxOutputTokens: 220,
    },
  };

  const commandEntrySchema = {
    type: "object",
    additionalProperties: false,
    properties: {
      action: {
        type: "string",
        enum: ["next", "previous", "goto", "mark", "stay"],
        description: "Slide control action",
      },
      target_slide: {
        type: ["integer", "null"],
        description: "Required when action is goto, otherwise null",
      },
      mark_index: {
        type: ["integer", "null"],
        description: "Required and non-null when action is mark, otherwise null",
      },
      confidence: {
        type: "number",
        minimum: 0,
        maximum: 1,
        description: "Model confidence in the command",
      },
      rationale: {
        type: "string",
        description: "Short factual explanation for the selected action (2-6 words)",
      },
      utterance_excerpt: {
        type: ["string", "null"],
        description:
          "Exact excerpt of the triggering utterance (max 6 words); required for navigation actions and null allowed otherwise",
      },
      highlight_phrases: {
        type: "array",
        items: { type: "string" },
        maxItems: 3,
        description: "Optional phrases from current slide to highlight based on what was just said; [] when none",
      },
    },
    required: ["action", "target_slide", "mark_index", "confidence", "rationale", "utterance_excerpt", "highlight_phrases"],
  };

  const commandToolSchema = {
    type: "function",
    name: "emit_slide_command",
    description: "Return one ordered command batch for slide navigation/highlighting based on presenter speech and current slide context.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        commands: {
          type: "array",
          minItems: 1,
          maxItems: 6,
          items: commandEntrySchema,
          description: "Ordered atomic commands for this speech turn",
        },
      },
      required: ["commands"],
    },
  };

  const forwardedEventTypes = new Set([
    "error",
    "response.created",
    "response.done",
    "response.function_call_arguments.delta",
    "response.function_call_arguments.done",
    "input_audio_buffer.speech_started",
    "input_audio_buffer.speech_stopped",
    "response.output_item.done",
  ]);
  const eventTypeRegex = /"type"\s*:\s*"([^"]+)"/;

  function post(kind, payload = {}) {
    if (!messageHandler) {
      return;
    }
    messageHandler.postMessage({ kind, ...payload });
  }

  function log(level, message, data) {
    post("log", { level, message, data });
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function configureManualMode(config) {
    const manual = state.manual;
    const requestedCommitIntervalMs = Number(config?.manualCommitIntervalMs);
    const requestedMaxOutputTokens = Number(config?.maxOutputTokens);

    if (Number.isFinite(requestedCommitIntervalMs)) {
      manual.commitIntervalMs = clamp(Math.round(requestedCommitIntervalMs), 120, 1000);
    }

    if (Number.isFinite(requestedMaxOutputTokens)) {
      manual.maxOutputTokens = clamp(Math.round(requestedMaxOutputTokens), 80, 420);
    }
  }

  function emitLocalSpeechState(active, rms = 0) {
    const type = active
      ? "input_audio_buffer.speech_started"
      : "input_audio_buffer.speech_stopped";
    post("event", {
      event: {
        type,
        source: "local_manual",
        rms,
      },
    });
  }

  function tickLocalSpeechMonitor() {
    const manual = state.manual;
    if (!manual.analyser || !manual.analyserData) {
      return;
    }

    manual.analyser.getFloatTimeDomainData(manual.analyserData);
    let energy = 0;
    for (let i = 0; i < manual.analyserData.length; i += 1) {
      const sample = manual.analyserData[i];
      energy += sample * sample;
    }

    const rms = Math.sqrt(energy / manual.analyserData.length);
    const now = Date.now();

    if (rms >= manual.rmsThreshold) {
      manual.lastSpeechAt = now;
      if (!manual.speechActive) {
        manual.speechActive = true;
        manual.speechStartedAt = now;
        emitLocalSpeechState(true, rms);
      }
      return;
    }

    if (manual.speechActive && now - manual.lastSpeechAt > manual.speechTailMs) {
      manual.speechActive = false;
      emitLocalSpeechState(false, rms);
    }
  }

  function requestManualResponseCycle() {
    if (!state.dc || state.dc.readyState !== "open") {
      return;
    }

    const manual = state.manual;
    const now = Date.now();

    if (manual.pendingResponse) {
      if (now - manual.pendingSince < manual.responseTimeoutMs) {
        return;
      }
      manual.pendingResponse = false;
      manual.pendingSince = 0;
      log("warn", "Manual response timeout reached; resetting cycle");
    }

    const speechWindowOpen =
      manual.speechActive ||
      (manual.lastSpeechAt > 0 && now - manual.lastSpeechAt <= manual.speechTailMs);
    if (!speechWindowOpen) {
      return;
    }

    if (
      manual.speechActive &&
      manual.speechStartedAt > 0 &&
      now - manual.speechStartedAt < manual.minSpeechLeadMs
    ) {
      return;
    }

    if (!sendEvent({ type: "input_audio_buffer.commit" })) {
      return;
    }

    const didSendCreate = sendEvent({
      type: "response.create",
      response: {
        tool_choice: "required",
        max_output_tokens: manual.maxOutputTokens,
      },
    });

    if (!didSendCreate) {
      return;
    }

    manual.pendingResponse = true;
    manual.pendingSince = now;
  }

  function handleInternalServerEvent(event) {
    const manual = state.manual;
    if (!event || typeof event !== "object") {
      return;
    }

    if (event.type === "response.created") {
      manual.pendingResponse = true;
      manual.pendingSince = Date.now();
      return;
    }

    if (event.type === "response.done" || event.type === "error") {
      manual.pendingResponse = false;
      manual.pendingSince = 0;
    }
  }

  function stopManualMode() {
    const manual = state.manual;

    if (manual.commitTimer) {
      window.clearInterval(manual.commitTimer);
      manual.commitTimer = null;
    }

    if (manual.monitorTimer) {
      window.clearInterval(manual.monitorTimer);
      manual.monitorTimer = null;
    }

    if (manual.sourceNode) {
      try {
        manual.sourceNode.disconnect();
      } catch (_) {
        // Ignore disconnect errors during teardown.
      }
      manual.sourceNode = null;
    }

    if (manual.audioContext) {
      try {
        void manual.audioContext.close();
      } catch (_) {
        // Ignore close errors during teardown.
      }
      manual.audioContext = null;
    }

    manual.analyser = null;
    manual.analyserData = null;
    manual.speechActive = false;
    manual.speechStartedAt = 0;
    manual.lastSpeechAt = 0;
    manual.pendingResponse = false;
    manual.pendingSince = 0;
  }

  function startManualMode(stream, config) {
    stopManualMode();
    configureManualMode(config);

    const manual = state.manual;
    manual.commitTimer = window.setInterval(
      requestManualResponseCycle,
      manual.commitIntervalMs
    );

    try {
      const audioContext = new window.AudioContext();
      const sourceNode = audioContext.createMediaStreamSource(stream);
      const analyser = audioContext.createAnalyser();
      analyser.fftSize = 1024;
      analyser.smoothingTimeConstant = 0.2;
      sourceNode.connect(analyser);

      manual.audioContext = audioContext;
      manual.sourceNode = sourceNode;
      manual.analyser = analyser;
      manual.analyserData = new Float32Array(analyser.fftSize);
      manual.monitorTimer = window.setInterval(tickLocalSpeechMonitor, 40);

      if (audioContext.state === "suspended") {
        void audioContext.resume().catch((error) => {
          log("warn", `Manual speech monitor resume failed: ${error}`);
        });
      }

      log("info", "Manual realtime mode enabled", {
        commit_interval_ms: manual.commitIntervalMs,
        rms_threshold: manual.rmsThreshold,
      });
    } catch (error) {
      // Fallback mode: keep cycling without local speech gating.
      manual.speechActive = true;
      manual.speechStartedAt = Date.now();
      manual.lastSpeechAt = Date.now();
      log("warn", "Manual speech monitor unavailable; using timer-only commit loop", {
        error: String(error),
        commit_interval_ms: manual.commitIntervalMs,
      });
    }
  }

  async function stopSession() {
    stopManualMode();

    if (state.dc) {
      try {
        state.dc.close();
      } catch (error) {
        log("warn", `Error closing data channel: ${error}`);
      }
      state.dc = null;
    }

    if (state.pc) {
      try {
        state.pc.close();
      } catch (error) {
        log("warn", `Error closing peer connection: ${error}`);
      }
      state.pc = null;
    }

    if (state.localStream) {
      state.localStream.getTracks().forEach((track) => track.stop());
      state.localStream = null;
    }

    post("connection", { state: "closed" });
  }

  function defaultSessionUpdate(instructions, maxOutputTokens) {
    return {
      type: "realtime",
      output_modalities: ["text"],
      instructions,
      tool_choice: "required",
      tools: [commandToolSchema],
      audio: {
        input: {
          turn_detection: null,
        },
      },
      max_output_tokens: maxOutputTokens ?? 220,
    };
  }

  function sendEvent(event) {
    if (!state.dc || state.dc.readyState !== "open") {
      log("warn", "Data channel is not open; event dropped", event);
      return false;
    }
    state.dc.send(JSON.stringify(event));
    return true;
  }

  function shouldForwardServerEvent(event) {
    if (!event || typeof event !== "object") {
      return false;
    }
    const type = event.type;
    if (typeof type !== "string") {
      return false;
    }
    if (!forwardedEventTypes.has(type)) {
      return false;
    }

    if (type === "response.output_item.done") {
      return event.item?.type === "function_call";
    }

    return true;
  }

  function shouldParseServerEventPayload(rawPayload) {
    if (typeof rawPayload !== "string" || rawPayload.length === 0) {
      return false;
    }

    const match = rawPayload.match(eventTypeRegex);
    if (!match || match.length < 2) {
      return false;
    }

    const type = match[1];
    if (!forwardedEventTypes.has(type)) {
      return false;
    }

    return true;
  }

  async function startSession(config) {
    if (!config?.clientSecret) {
      throw new Error("startSession missing clientSecret");
    }

    await stopSession();

    const pc = new RTCPeerConnection();
    state.pc = pc;

    pc.onconnectionstatechange = () => {
      post("connection", { state: pc.connectionState });
    };

    pc.oniceconnectionstatechange = () => {
      post("connection", { state: `ice:${pc.iceConnectionState}` });
    };

    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    state.localStream = stream;

    stream.getTracks().forEach((track) => {
      pc.addTrack(track, stream);
    });

    const dc = pc.createDataChannel("oai-events");
    state.dc = dc;

    dc.onopen = () => {
      log("info", "Realtime data channel opened");
      configureManualMode(config);
      const sessionUpdate = defaultSessionUpdate(
        config.instructions,
        state.manual.maxOutputTokens
      );
      sendEvent({ type: "session.update", session: sessionUpdate });
      startManualMode(stream, config);
    };

    dc.onmessage = (event) => {
      try {
        const rawPayload = String(event.data ?? "");
        if (!shouldParseServerEventPayload(rawPayload)) {
          return;
        }

        const parsed = JSON.parse(rawPayload);
        handleInternalServerEvent(parsed);
        if (shouldForwardServerEvent(parsed)) {
          post("event", { event: parsed });
        }
      } catch (error) {
        log("error", `Failed to parse server event JSON: ${error}`, { payload: event.data });
      }
    };

    dc.onerror = (event) => {
      log("error", "Data channel error", { event: String(event) });
    };
    dc.onclose = () => {
      log("warn", "Realtime data channel closed");
    };

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    const sdpResponse = await fetch("https://api.openai.com/v1/realtime/calls", {
      method: "POST",
      body: offer.sdp,
      headers: {
        Authorization: `Bearer ${config.clientSecret}`,
        "Content-Type": "application/sdp",
      },
    });

    if (!sdpResponse.ok) {
      const details = await sdpResponse.text();
      throw new Error(`Realtime call failed (${sdpResponse.status}): ${details}`);
    }

    const answer = {
      type: "answer",
      sdp: await sdpResponse.text(),
    };

    await pc.setRemoteDescription(answer);
    log("info", "Realtime WebRTC session established", { model: config.model });
  }

  async function updateSession(payload) {
    if (!payload?.instructions) {
      return;
    }

    configureManualMode(payload);
    const sessionUpdate = defaultSessionUpdate(
      payload.instructions,
      state.manual.maxOutputTokens
    );
    sendEvent({ type: "session.update", session: sessionUpdate });

    if (state.manual.commitTimer) {
      window.clearInterval(state.manual.commitTimer);
      state.manual.commitTimer = window.setInterval(
        requestManualResponseCycle,
        state.manual.commitIntervalMs
      );
    }
  }

  window.AutoPresenter = {
    startSession,
    stopSession,
    updateSession,
  };
})();
