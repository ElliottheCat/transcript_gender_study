from transformers import pipeline


def get_oss_output(query: str)-> str:
    """
    Get the output from the OpenAI GPT-OSS model for a given query.
    """

    model_id = "openai/gpt-oss-20b"
    pipe = pipeline(
        "text-generation",
        model=model_id,
        torch_dtype="auto",
        device_map="auto",
    )

    outputs = pipe([{"role": "user", "content": query}], max_new_tokens=256)
    print(outputs[0]["generated_text"][-1])
    return outputs[0]["generated_text"][-1]


