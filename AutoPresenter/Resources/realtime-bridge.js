(() => {
  const messageHandler = window.webkit?.messageHandlers?.autoPresenterBridge;

  const state = {
    pc: null,
    dc: null,
    localStream: null,
  };

  const commandEntrySchema = {
    type: "object",
    additionalProperties: false,
    properties: {
      action: {
        type: "string",
        enum: ["next", "previous", "goto", "mark", "stay"],
        description: "Slide control action. Must be one of next|previous|goto|mark|stay.",
      },
      target_slide: {
        type: ["integer", "null"],
        description: "MUST be integer only when action=goto. MUST be null for all other actions.",
      },
      mark_index: {
        type: ["integer", "null"],
        description: "MUST be integer only when action=mark. MUST be null for all other actions.",
      },
      confidence: {
        type: "number",
        minimum: 0,
        maximum: 1,
        description: "Model confidence in [0,1].",
      },
      rationale: {
        type: "string",
        description: "Short factual explanation (4-10 words). No flourish.",
      },
      utterance_excerpt: {
        type: ["string", "null"],
        description: "Exact quote from utterance (max 10 words) or null.",
      },
      highlight_phrases: {
        type: "array",
        items: { type: "string" },
        maxItems: 5,
        description: "0-5 exact current-slide substrings only. Use [] when none.",
      },
    },
    required: ["action", "target_slide", "mark_index", "confidence", "rationale", "utterance_excerpt", "highlight_phrases"],
  };

  const commandToolSchema = {
    type: "function",
    name: "emit_slide_command",
    description: "Strict command contract. Return one ordered command batch for this turn. Invalid, partial, or schema-breaking payloads are rejected.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        commands: {
          type: "array",
          minItems: 1,
          maxItems: 6,
          items: commandEntrySchema,
          description: "Ordered atomic commands for this speech turn. Use stay when uncertain.",
        },
      },
      required: ["commands"],
    },
  };

  const forwardedEventTypes = new Set([
    "error",
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

  async function stopSession() {
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

  function defaultSessionUpdate(instructions, turnDetection) {
    return {
      type: "realtime",
      output_modalities: ["text"],
      instructions,
      tool_choice: "required",
      tools: [commandToolSchema],
      audio: {
        input: {
          turn_detection: {
            type: turnDetection?.type ?? "server_vad",
            create_response: turnDetection?.create_response ?? true,
            interrupt_response: turnDetection?.interrupt_response ?? true,
            silence_duration_ms: turnDetection?.silence_duration_ms ?? 420,
          },
        },
      },
      max_output_tokens: 720,
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
      const sessionUpdate = defaultSessionUpdate(config.instructions, config.turnDetection);
      sendEvent({ type: "session.update", session: sessionUpdate });
    };

    dc.onmessage = (event) => {
      try {
        const rawPayload = String(event.data ?? "");
        if (!shouldParseServerEventPayload(rawPayload)) {
          return;
        }

        const parsed = JSON.parse(rawPayload);
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

    const sessionUpdate = defaultSessionUpdate(payload.instructions);
    sendEvent({ type: "session.update", session: sessionUpdate });
  }

  window.AutoPresenter = {
    startSession,
    stopSession,
    updateSession,
  };
})();
