from typing import List, Dict, Any


from llama_index.core.extractors import BaseExtractor
from llama_index.core.schema import BaseNode
from llama_index.llms.openai import OpenAI


from .gpt_oss import get_oss_output
from .topics import TOPIC_CATEGORIES


def categorize_topics(topic:str)-> str:
    """Categorize a topic into predefined categories."""
    topic_lower=topic.lower()
    # Check if topic matches any predefined categories
    for category, keywords in TOPIC_CATEGORIES.items():
        if any(keyword in topic_lower for keyword in keywords):
            return category
    return "other"

class TopicExtractor(BaseExtractor):
    """Extracts main topics and themes from interview transcripts."""
    def __init__(self, llm: OpenAI):
        super().__init__()
        self.llm = llm
        self.category_list = list(TOPIC_CATEGORIES.keys())

    async def aextract(self,nodes:List[BaseNode])->List[Dict[str,Any]]:
        metadata_list=[]
        for node in nodes:
            # Create prompt for topic extraction
            prompt = f"""Analyze this interview transcript segment and identify which of these topic categories apply: 
            Categories: {', '.join(self.category_list)}
            Text:{node.text}
            Return only the relevant categories as a comma-separated list.
            If none apply, return "other".
            Categories:"""
            
            response = await self.llm.acomplete(prompt)
            categories=[cat.strip() for cat in str(response).split(',')]

            # Count frequency of each category
            category_counts = {}
            for cat in categories:
                if cat in self.category_list or cat == "other":
                    category_counts[cat] = category_counts.get(cat,0) + 1

            metadata_list.append({
                "topic_categories": categories,
                "category_counts": category_counts,
            })
        return metadata_list
    

class GenderExtractor(BaseExtractor):
    """Identifies interviewee gender for gender studies research."""
    def __init__(self, llm:OpenAI):
        super().__init__()
        self.llm=llm

    async def aextract(self,nodes:List[BaseNode])-> List[Dict[str,Any]]:
        metadata_list = []
        
        for node in nodes:
            prompt = f"""
            Based on this interview transcript, identify the interviewee's gender.
            Look for pronouncs, self-identification, or contextual clues.

            text: {node.text}

            Respond with one of: male or female

            Gender:"""

            response= await self.llm.acomplete(prompt)
            gender=str(response).strip().lower()

            #validate response
            valid_genders = ["male","female"]
            if gender not in valid_genders:
                gender = "unclear"

            metadata_list.append({
                "interviewee_gender": gender,
                "source_filename": node.metadata.get("filename",
  "unknown"),
                "source_index": node.metadata.get("index",
  "unknown"),
                "source_title": node.metadata.get("title", "unknown")
            })
        return metadata_list




class SpeakerExtractor(BaseExtractor):
    """Extracts speaker information and dialogue patterns from interviews."""
    def __init__(self,llm:OpenAI):
        super().__init__()
        self.llm=llm

    async def aextract(self,nodes:List[BaseNode]) -> List[Dict[str,Any]]:
        metadata_list = []
        for node in nodes:
            prompt = f"""
    Analyze this interview transcript segment and identify:
    1. Number of distinct speaker
    2. Speaker roles (interviewer, interviewee, moderator, etc.)
    3. Who speaks the most in this segment

    Text: {node.text}
    Format your response as:
    Speakers: [number]
    Roles: [role1, role2, ...]
    Primary speaker: [role]
    """
            
        response = await self.llm.acomplete(prompt)
        response_text = str(response)

        # Parse response
        speakers = self._extract_number(response_text, "Speakers:")
        roles = self._extract_list(response_text, "Roles:")
        primary = self._extract_value(response_text, "Primary speaker:")

        metadata_list.append({
            "speaker_count": speakers,
            "speaker_roles": roles,
            "primary_speaker": primary,
            "has_dialogue": speakers > 1
        })

        return metadata_list
    

    def _extract_number(self, text:str, prefix:str) -> int:
        try:
            line = [l for l in text.split('\n') if prefix in l][0]
            return int(line.split(prefix)[1].strip())
        except:
            return 0
        
    def _extract_list(self, text:str, prefix:str) -> List[str]:
        try: 
            line = [l for l in text.split('\n') if prefix in l][0]
            items = line.split(prefix)[1].strip()
            return [item.strip() for item in items.replace('[', '').replace(']','').split(',')]
        except:
            return []
        
    def _extract_value(self, text:str, prefix:str) -> str:
        try:
            line = [l for l in text.split('\n') if prefix in l][0]
            return line.split(prefix)[1].strip()
        except:
            return "unknown"
 