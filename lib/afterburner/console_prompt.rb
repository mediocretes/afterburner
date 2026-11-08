# frozen_string_literal: true

# Not required: `afterburner console` loads this the way a script is loaded,
# wrapped in a fresh ScriptContext module, and runs IRB on the binding it
# leaves here. So the prompt is a script's top level. See Console#prompt_binding.
Fiber[:afterburner_prompt] = binding
