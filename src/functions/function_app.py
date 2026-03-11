"""
Azure Functions — Customer Enquiry Hub
=======================================
Three functions in a single v4 Python app:

  1. process_enquiry  — Service Bus / Storage Queue trigger
                        Classifies enquiry with Azure OpenAI, stores enriched
                        record in Cosmos DB, raises Event Grid alert if Critical.

  2. submit_enquiry   — HTTP POST /submit
                        Accepts a new enquiry from APIM and enqueues it.

  3. chat_endpoint    — HTTP POST /chat
                        Staff-facing conversational assistant that answers
                        questions based on recent enquiry data.

Messaging path selection
------------------------
Set the MESSAGING_PATH app setting in Azure (Terraform manages this):
  standard / premium  → Service Bus trigger + ServiceBusClient sender  (default)
  storagequeue        → Storage Queue trigger + QueueClient sender

The correct trigger variant is registered at import time based on MESSAGING_PATH.
No code changes are needed to switch paths — only the Terraform variable.
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone

import azure.functions as func
from azure.cosmos import CosmosClient
from azure.eventgrid import EventGridEvent, EventGridPublisherClient
from azure.identity import DefaultAzureCredential
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from azure.storage.queue import QueueClient
from openai import AzureOpenAI

# ─────────────────────────────────────────────────────────────────────────────
# Configuration — read at import time with safe defaults.
#
# All values use .get() with a fallback so this module can be imported in unit
# tests without every environment variable present. The actual values are
# provided by the Function App app_settings block in Terraform.
# ─────────────────────────────────────────────────────────────────────────────

MESSAGING_PATH    = os.environ.get("MESSAGING_PATH", "standard")
COSMOS_ENDPOINT   = os.environ.get("COSMOS_ENDPOINT", "")
COSMOS_DATABASE   = os.environ.get("COSMOS_DATABASE", "EnquiryHub")
COSMOS_CONTAINER  = os.environ.get("COSMOS_CONTAINER", "Enquiries")
OPENAI_ENDPOINT   = os.environ.get("OPENAI_ENDPOINT", "")
OPENAI_DEPLOYMENT = os.environ.get("OPENAI_DEPLOYMENT", "gpt-4o")
SB_FQDN           = os.environ.get("SERVICE_BUS_FQDN", "")
SB_QUEUE          = os.environ.get("SERVICE_BUS_QUEUE", "enquiry-queue")
STORAGE_QUEUE_CONN = os.environ.get("AzureWebJobsQueueStorage", "")
EVENTGRID_ENDPOINT = os.environ.get("EVENTGRID_TOPIC_ENDPOINT", "")

# ─────────────────────────────────────────────────────────────────────────────
# Lazy client getters
#
# Clients are created on first call and then cached in module-level variables.
# This approach avoids two problems:
#   1. Import-time failures when env vars aren't set (e.g. in unit tests).
#   2. Re-creating SDK objects on every invocation (expensive for warm workers).
#
# In tests, patch these getter functions (e.g. `patch("function_app._get_openai_client")`)
# rather than patching the SDK constructors directly.
# ─────────────────────────────────────────────────────────────────────────────

_credential:       "DefaultAzureCredential | None" = None
_cosmos_container: "object | None"                 = None
_openai_client:    "AzureOpenAI | None"            = None
_eg_client:        "EventGridPublisherClient | None" = None


def _get_credential() -> DefaultAzureCredential:
    global _credential
    if _credential is None:
        _credential = DefaultAzureCredential()
    return _credential


def _get_openai_token() -> str:
    """Token provider callback invoked by the AzureOpenAI SDK before each request."""
    return _get_credential().get_token("https://cognitiveservices.azure.com/.default").token


def _get_cosmos_container():
    """Return the Cosmos DB container client, initialising it on first call."""
    global _cosmos_container
    if _cosmos_container is None:
        client = CosmosClient(url=COSMOS_ENDPOINT, credential=_get_credential())
        _cosmos_container = (
            client
            .get_database_client(COSMOS_DATABASE)
            .get_container_client(COSMOS_CONTAINER)
        )
    return _cosmos_container


def _get_openai_client() -> AzureOpenAI:
    """Return the AzureOpenAI client, initialising it on first call."""
    global _openai_client
    if _openai_client is None:
        _openai_client = AzureOpenAI(
            azure_endpoint=OPENAI_ENDPOINT,
            azure_ad_token_provider=_get_openai_token,
            api_version="2024-02-01",
        )
    return _openai_client


def _get_eventgrid_client() -> EventGridPublisherClient:
    """Return the Event Grid publisher client, initialising it on first call.

    Uses managed identity (DefaultAzureCredential) — requires the Function App's
    identity to have the 'EventGrid Data Sender' role on the topic (see rbac.tf).
    """
    global _eg_client
    if _eg_client is None:
        _eg_client = EventGridPublisherClient(
            endpoint=EVENTGRID_ENDPOINT,
            credential=_get_credential(),
        )
    return _eg_client


# ─────────────────────────────────────────────────────────────────────────────
# Azure Functions app
# ─────────────────────────────────────────────────────────────────────────────

app = func.FunctionApp()


# ─────────────────────────────────────────────────────────────────────────────
# Business logic helpers
#
# Extracted from the trigger-decorated functions so they can be unit-tested
# directly without needing mock trigger message objects.
# ─────────────────────────────────────────────────────────────────────────────

_CLASSIFICATION_SYSTEM_PROMPT = """\
You are an AI classifier for a business customer enquiry system.
Given the sender, subject, and body of an enquiry, return a JSON object with
exactly these fields:

  urgency         : "Critical" | "High" | "Medium" | "Low"
  category        : "Complaint" | "Quote Request" | "Support" | "General"
  summary         : A one-sentence summary of the enquiry (max 120 chars)
  suggested_action: A brief recommended next step for the support team

Respond with valid JSON only — no markdown, no explanation.
"""


def _classify_enquiry(sender: str, subject: str, body: str) -> dict:
    """Call Azure OpenAI to classify an enquiry.

    Returns a dict with keys: urgency, category, summary, suggested_action.
    Raises on OpenAI error or JSON parse failure — the caller is responsible
    for letting the message be dead-lettered after max retries.
    """
    response = _get_openai_client().chat.completions.create(
        model=OPENAI_DEPLOYMENT,
        messages=[
            {"role": "system", "content": _CLASSIFICATION_SYSTEM_PROMPT},
            {"role": "user", "content": f"Sender: {sender}\nSubject: {subject}\nBody:\n{body}"},
        ],
        # json_object mode prevents the model from wrapping output in prose/markdown
        response_format={"type": "json_object"},
        temperature=0.1,   # Low temperature → deterministic classification
        max_tokens=256,
    )
    return json.loads(response.choices[0].message.content)


def _build_document(
    sender: str,
    subject: str,
    body: str,
    urgency: str,
    category: str,
    summary: str,
    suggested_action: str,
) -> dict:
    """Build the enriched Cosmos DB document from raw fields and classification results.

    Pure function — no side effects, easy to unit-test.
    """
    now = datetime.now(timezone.utc)
    return {
        "id":              str(uuid.uuid4()),
        "dateKey":         now.strftime("%Y-%m-%d"),   # Partition key (/dateKey)
        "timestamp":       now.isoformat(),
        "sender":          sender,
        "subject":         subject,
        "body":            body,
        "urgency":         urgency,
        "category":        category,
        "summary":         summary,
        "suggestedAction": suggested_action,
        "status":          "Open",
    }


def _publish_critical_alert(
    enquiry_id: str,
    sender: str,
    summary: str,
    category: str,
) -> None:
    """Publish a Critical enquiry event to the Event Grid topic.

    A Logic App subscription converts the event into an email alert.
    Failure is logged but NOT re-raised so it does not roll back the Cosmos write —
    a failed alert is less harmful than losing the stored enquiry record.
    """
    event = EventGridEvent(
        event_type="EnquiryHub.Enquiry.Critical",
        subject=f"enquiries/{enquiry_id}",
        data_version="1.0",
        data={
            "enquiry_id": enquiry_id,
            "sender":     sender,
            "summary":    summary,
            "category":   category,
        },
    )
    try:
        _get_eventgrid_client().send([event])
        logging.info("Published Critical alert for enquiry %s", enquiry_id)
    except Exception as exc:
        logging.error("Failed to publish Event Grid alert for %s: %s", enquiry_id, exc)


def _process_enquiry_impl(message_json: str) -> None:
    """Core processing logic called by both trigger variants.

    Separated from the decorated functions so it can be called directly in tests
    with a plain JSON string, without needing a mock ServiceBusMessage or QueueMessage.

    Raises:
        Exception: Re-raised from _classify_enquiry so the message is dead-lettered
                   on persistent failures rather than silently discarded.
    """
    payload = json.loads(message_json)
    sender  = payload.get("sender", "unknown")
    subject = payload.get("subject", "(no subject)")
    body    = payload.get("body", "")

    logging.info("Processing enquiry from '%s' — subject: %s", sender, subject)

    # Re-raise on classification failure — message will be dead-lettered
    # after the broker's max-delivery-count is reached, preserving it for review.
    classification   = _classify_enquiry(sender, subject, body)
    urgency          = classification.get("urgency", "Medium")
    category         = classification.get("category", "General")
    summary          = classification.get("summary", "")
    suggested_action = classification.get("suggested_action", "")

    document = _build_document(sender, subject, body, urgency, category, summary, suggested_action)
    _get_cosmos_container().upsert_item(document)
    logging.info("Stored enquiry %s (urgency=%s, category=%s)", document["id"], urgency, category)

    if urgency == "Critical":
        _publish_critical_alert(document["id"], sender, summary, category)


# ─────────────────────────────────────────────────────────────────────────────
# Function 1: process_enquiry — conditional trigger registration
#
# The if/else runs at import time, registering exactly ONE trigger variant
# based on MESSAGING_PATH. This is syntactically valid Python and avoids the
# comment-in / comment-out approach which would cause syntax errors.
# ─────────────────────────────────────────────────────────────────────────────

if MESSAGING_PATH in ("standard", "premium"):
    # ── Path A / B — Service Bus queue trigger ────────────────────────────────
    # The `connection` value must match the app setting name whose value is the
    # namespace FQDN. The Functions host appends __fullyQualifiedNamespace to
    # the setting name when looking up the connection string.
    @app.service_bus_queue_trigger(
        arg_name="msg",
        queue_name="enquiry-queue",
        connection="SERVICE_BUS_FQDN",
    )
    def process_enquiry(msg: func.ServiceBusMessage) -> None:
        """Service Bus trigger — active for messaging_path = standard or premium."""
        _process_enquiry_impl(msg.get_body().decode("utf-8"))

else:
    # ── Path C — Azure Storage Queue trigger ──────────────────────────────────
    # Storage Queue messages are base64-encoded by _send_to_storage_queue;
    # the Functions host decodes them before calling get_body().
    @app.queue_trigger(
        arg_name="msg",
        queue_name="enquiry-queue",
        connection="AzureWebJobsQueueStorage",
    )
    def process_enquiry(msg: func.QueueMessage) -> None:
        """Storage Queue trigger — active for messaging_path = storagequeue."""
        _process_enquiry_impl(msg.get_body().decode("utf-8"))


# ─────────────────────────────────────────────────────────────────────────────
# Messaging senders — one per path, selected at module load time
# ─────────────────────────────────────────────────────────────────────────────

def _send_to_service_bus(message_body: str) -> None:
    """Enqueue a message on the Service Bus queue using managed identity.

    Uses a context manager so the connection is closed after sending,
    which is appropriate for the low-throughput submit path.
    """
    with ServiceBusClient(
        fully_qualified_namespace=SB_FQDN,
        credential=_get_credential(),
    ) as sb_client:
        with sb_client.get_queue_sender(queue_name=SB_QUEUE) as sender_client:
            sender_client.send_messages(ServiceBusMessage(message_body))


def _send_to_storage_queue(message_body: str) -> None:
    """Enqueue a message on the Azure Storage Queue (base64 encoded).

    Base64 encoding is required because the Azure Functions Storage Queue trigger
    expects messages to be base64-encoded, and will decode them before calling
    get_body() in the trigger handler.
    """
    import base64
    encoded = base64.b64encode(message_body.encode()).decode()
    client = QueueClient.from_connection_string(STORAGE_QUEUE_CONN, "enquiry-queue")
    client.send_message(encoded)


# Select the active sender function at module load time — submit_enquiry calls
# _send_enquiry without needing to branch on MESSAGING_PATH at runtime.
_send_enquiry = (
    _send_to_service_bus
    if MESSAGING_PATH in ("standard", "premium")
    else _send_to_storage_queue
)


# ─────────────────────────────────────────────────────────────────────────────
# Function 2: submit_enquiry — HTTP POST /submit
# ─────────────────────────────────────────────────────────────────────────────

@app.route(route="submit", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def submit_enquiry(req: func.HttpRequest) -> func.HttpResponse:
    """Accept an enquiry payload from APIM and place it on the messaging queue.

    Request body (JSON):
      sender  (str, required) — customer email or name
      subject (str, required) — enquiry subject line
      body    (str, required) — full enquiry text

    Returns:
      202 { "message_id": "<uuid>", "status": "queued" }
      400 on validation failure
    """
    try:
        payload = req.get_json()
    except ValueError:
        return func.HttpResponse("Request body must be valid JSON.", status_code=400)

    missing = [f for f in ("sender", "subject", "body") if not payload.get(f)]
    if missing:
        return func.HttpResponse(
            f"Missing required fields: {', '.join(missing)}",
            status_code=400,
        )

    _send_enquiry(json.dumps(payload))
    message_id = str(uuid.uuid4())
    logging.info("Enqueued enquiry from '%s' (msg_id=%s)", payload["sender"], message_id)

    return func.HttpResponse(
        json.dumps({"message_id": message_id, "status": "queued"}),
        status_code=202,
        mimetype="application/json",
    )


# ─────────────────────────────────────────────────────────────────────────────
# Function 3: chat_endpoint — HTTP POST /chat
# ─────────────────────────────────────────────────────────────────────────────

_CHAT_SYSTEM_PROMPT = """\
You are a helpful business assistant for the Enquiry Hub support team.
You have access to recent customer enquiries provided as JSON context.
Answer the user's question based on this data only.
Be concise and factual. If the data does not contain enough information to
answer, say so clearly rather than guessing.
"""

# Fetches the 50 most recent enquiries across all partitions.
# Only summary fields are selected (not the full body) to keep the
# context window small and reduce OpenAI token costs.
_COSMOS_RECENT_QUERY = (
    "SELECT c.id, c.dateKey, c.timestamp, c.sender, c.subject, "
    "c.urgency, c.category, c.summary, c.suggestedAction, c.status "
    "FROM c ORDER BY c.timestamp DESC OFFSET 0 LIMIT 50"
)


@app.route(route="chat", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def chat_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """Answer a staff question using recent enquiry data as context.

    Request body (JSON):
      question (str, required) — the staff member's natural language question

    Returns:
      200 { "answer": "<string>" }
      400 on validation failure
    """
    try:
        payload = req.get_json()
    except ValueError:
        return func.HttpResponse("Request body must be valid JSON.", status_code=400)

    question = payload.get("question", "").strip()
    if not question:
        return func.HttpResponse("Missing 'question' field.", status_code=400)

    # enable_cross_partition_query=True is required because _COSMOS_RECENT_QUERY
    # does not filter on the partition key (/dateKey), so results span partitions.
    items = list(
        _get_cosmos_container().query_items(
            query=_COSMOS_RECENT_QUERY,
            enable_cross_partition_query=True,
        )
    )

    response = _get_openai_client().chat.completions.create(
        model=OPENAI_DEPLOYMENT,
        messages=[
            {"role": "system", "content": _CHAT_SYSTEM_PROMPT},
            {
                "role": "user",
                "content": (
                    f"Recent enquiries (JSON):\n{json.dumps(items, indent=2)}\n\n"
                    f"Question: {question}"
                ),
            },
        ],
        temperature=0.3,
        max_tokens=512,
    )

    return func.HttpResponse(
        json.dumps({"answer": response.choices[0].message.content.strip()}),
        status_code=200,
        mimetype="application/json",
    )
