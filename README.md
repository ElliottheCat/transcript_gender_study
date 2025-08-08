# Holocaust Gender Study -- Topic Extraction for USHMM Transcripts 

This directory is dedicated towards the AI and Cultural Heritage Lab at UCLA. This project studies how to effectively extract categorizable and accurate topics from a testimony interview. We base our 

### Using LLM on remote servers (e.g. GPT-OSS-120B)

We may want to run larger models for better results. Using a remote server with GPU/VRAM that meets the requirement is the ideal setup. Here's how to connect your local code to the remote server (assuming you have a hoffman2 account):

1. **SSH Tunnel Setup**

    Create an SSH tunnel to forward the remote server's port to your local machine:

    ```bash
    # Forward remote port 8000 to local port 8000
    ssh -L 8000:localhost:8000 username@hoffman2.idre.ucla.edu

    # Or run in background with -f flag
    ssh -f -N -L 8000:localhost:8000 username@hoffman2.idre.ucla.edu
    ```

2. **On the Remote Server (hoffman2)**

    SSH into your server and set up the model:

    ```bash
    # SSH into the server
    ssh username@hoffman2.idre.ucla.edu

    # Create a conda/virtual environment
    module load python  # If using module system
    python -m venv gpt_env
    source gpt_env/bin/activate

    # Install dependencies
    pip install vllm transformers torch

    # Start the model server (this will download the model first time)
    vllm serve openai/gpt-oss-120b --host 0.0.0.0 --port 8000

    # Alternative: if GPU memory issues, try the smaller model
    # vllm serve openai/gpt-oss-20b --host 0.0.0.0 --port 8000
    ```

3. **Update Your Local .env File**

    ```
    LOCAL_GPT_OSS=1
    GPT_OSS_MODEL=openai/gpt-oss-120b
    API_BASE=http://localhost:8000/v1
    API_KEY=fake
    ```

4. **Test the Connection**

    From your local machine (while SSH tunnel is running):

    ```bash
    curl -X POST "http://localhost:8000/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d '{
         "model": "openai/gpt-oss-120b",
         "messages": [{"role": "user", "content": "Hello, are you working?"}],
         "max_tokens": 50
      }'
    ```

5. **For Long-Running Sessions**

    Use screen/tmux on the remote server to keep the model running:

    ```bash
    # On remote server
    screen -S gpt_server
    # or: tmux new -s gpt_server

    # Start the model
    vllm serve openai/gpt-oss-120b --host 0.0.0.0 --port 8000

    # Detach: Ctrl+A, D (screen) or Ctrl+B, D (tmux)
    # Reattach later: screen -r gpt_server
    ```

6. **Alternative: Direct Remote Connection**

    If you want to connect directly without SSH tunnel, update your `.env`:

    ```
    LOCAL_GPT_OSS=1
    GPT_OSS_MODEL=openai/gpt-oss-120b
    API_BASE=http://hoffman2.idre.ucla.edu:8000/v1  # Direct connection
    API_KEY=fake
    ```

    *Note: This requires the remote server to allow external connections on port 8000.*

7. **Automated SSH Tunnel Script**

    Create a script `start_tunnel.sh`:

    ```bash
    #!/bin/bash
    echo "Starting SSH tunnel to hoffman2..."
    ssh -f -N -L 8000:localhost:8000 username@hoffman2.idre.ucla.edu
    echo "Tunnel established. Model available at localhost:8000"
    echo "To stop: pkill -f 'ssh.*8000:localhost:8000'"
    ```

Now you can run your local code and it will use the remote GPU server! The setup keeps all your data local while leveraging the remote computing power.
