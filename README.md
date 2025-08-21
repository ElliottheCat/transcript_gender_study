# Holocaust Gender Study -- Topic Extraction for USHMM Transcripts 

This directory is dedicated towards the AI and Cultural Heritage Lab at UCLA. This project studies how to effectively extract categorizable and accurate topics from a testimony interview. We base our 


### Methdology

First extract the topics and gender of the transcripts to a csv file using openAI API and LlamaIndex pdf
	- I am now thinking about using GPT OSS model since it's free and has close to 3o performance. 
	- **Who defines the topic? and who names it?** 
		- Topic modeling could be word based/semantic based
	- Do multiple runs for topic modeling! (e.g. recursively)
		- topic title + context
		- multiple interactions
	- Un-guardraiedl llm on hugging face?  
	- combination of traditional/unguardrailed/specific package
	- Fuzzy logic and multi criteria decision making?
	- 
- This will provide a list of relative topics and frequency (page count) they appear in the document 
	- Sum up frequency with word. 
	- Word cloud visualization
- Random sample: based on topic distribution, select 1-2 transcript from each category of topics (e.g. food) with highest frequency in that topic for both genders, do spot check to ensure the topics are related. 
	- Evaluate the difference/subtlety in experience. 
	- Try to find some unique experience that can be related to gender (e.g. menstruation with no hygiene product in concentration camp)
- By cross comparing the distributions of topics (and the number of interviewee in each gender), we can summarize patterns and compare the two experience difference. 
- Look into past project on question topic comparison between men and women testimonies 
	- https://holocaustresearchlab.com/book/digital-project-2/
	- https://holocaustresearchlab.com/book/digital-project-2/vha/#Fig-dp2.4-4
-  **How do you evaluate the quality of your topics?** 
	- find topic first, then do close reading. 


### Directory Breakdown

##### pdfs
- original pdf for the testimonies

##### pdf-to-txt
- scripts and intermediate folders for converting the pdf to txt file, then cleaning out metadata
    - pdf-to-txt/batch-pdftotext.py
        - batch process pdf to text
    - pdf-to-txt/clean-metadata.py
        - Removed metadata containing url or disclaimers (removed inrelevant metadata)
        - Scanned for colon (the lines are concatenated until a new line with colon.) for better layout (no content deletion)
        - add option - end-of-line hyphen to remove end of line hyphens of words

    - pdf-to-txt/comp-docs.py
        - dispalys the difference between scanned (precleaned) txt and cleaned txt in HTML (view on localhost)

##### ushmm-metadata
- scripts and csv files on downloading metadata, and using Gemini to infer gender from interviewee name and testimonial transcript.
    - ushmm-metadata/ushmm-metadata.csv
        - orginal metadata copied from the USHMM website
    - ushmm-metadata/metadata_with_gender.csv
        - gives name and gender 
    

##### STM-topic-extract
- STM topic extraction in R
    - still under construction.




### Using LLM on remote servers (e.g. GPT-OSS-120B) 
**vLLM doesn't work on the server due to config issues. I will spend more time on this if i need local llm.**

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
