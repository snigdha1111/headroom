from langchain_openai import ChatOpenAI

llm = ChatOpenAI(
    base_url="http://127.0.0.1:8787/v1",
    api_key="dummy",
    model="qwen3:8b"
)

response = llm.invoke("Explain LangGraph in 5 lines.")

print(response.content)