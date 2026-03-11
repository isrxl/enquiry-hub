"""
Unit tests for function_app.py
================================
Run with:
    cd src/functions
    pip install -r requirements.txt pytest
    pytest tests/ -v

All Azure SDK calls are mocked — no Azure credentials or live services required.

Structure
---------
  TestClassifyEnquiry       — _classify_enquiry() OpenAI call + JSON parsing
  TestBuildDocument         — _build_document() pure function
  TestPublishCriticalAlert  — _publish_critical_alert() Event Grid publish
  TestProcessEnquiryImpl    — _process_enquiry_impl() orchestration
  TestSubmitEnquiry         — submit_enquiry() HTTP handler (validation + send)
  TestChatEndpoint          — chat_endpoint() HTTP handler (validation + OpenAI)
  TestSendToServiceBus      — _send_to_service_bus() SDK interaction
  TestSendToStorageQueue    — _send_to_storage_queue() SDK interaction
"""

import base64
import json
import os
import sys
import unittest
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock, call, patch

# ─────────────────────────────────────────────────────────────────────────────
# Environment setup
#
# Must happen BEFORE importing function_app so that:
#   1. MESSAGING_PATH is set to "standard" — registers the Service Bus trigger.
#   2. All other env vars have safe non-empty values (some SDK constructors
#      validate them at object creation time).
# ─────────────────────────────────────────────────────────────────────────────

os.environ.update(
    {
        "MESSAGING_PATH":          "standard",
        "COSMOS_ENDPOINT":         "https://test.documents.azure.com:443/",
        "COSMOS_DATABASE":         "EnquiryHub",
        "COSMOS_CONTAINER":        "Enquiries",
        "OPENAI_ENDPOINT":         "https://test.openai.azure.com/",
        "OPENAI_DEPLOYMENT":       "gpt-4o",
        "SERVICE_BUS_FQDN":        "test.servicebus.windows.net",
        "SERVICE_BUS_QUEUE":       "enquiry-queue",
        "AzureWebJobsQueueStorage": "DefaultEndpointsProtocol=https;AccountName=test;AccountKey=dGVzdA==;EndpointSuffix=core.windows.net",
        "EVENTGRID_TOPIC_ENDPOINT": "https://test.eventgrid.azure.net/api/events",
    }
)

import azure.functions as func  # noqa: E402 — must follow env setup

import function_app  # noqa: E402 — must follow env setup


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _make_openai_response(content: str) -> MagicMock:
    """Build a mock object that matches the shape of an OpenAI chat completion."""
    message = MagicMock()
    message.content = content
    choice = MagicMock()
    choice.message = message
    response = MagicMock()
    response.choices = [choice]
    return response


def _make_http_request(body: dict | str | None = None, method: str = "POST") -> func.HttpRequest:
    """Construct a real func.HttpRequest for HTTP-triggered function tests."""
    if body is None:
        raw = b""
    elif isinstance(body, dict):
        raw = json.dumps(body).encode()
    else:
        raw = body.encode() if isinstance(body, str) else body

    return func.HttpRequest(
        method=method,
        url="https://func-enquiryhub-dev.azurewebsites.net/api/submit",
        body=raw,
        headers={"Content-Type": "application/json"},
    )


# ─────────────────────────────────────────────────────────────────────────────
# TestClassifyEnquiry
# ─────────────────────────────────────────────────────────────────────────────

class TestClassifyEnquiry(unittest.TestCase):
    """Tests for _classify_enquiry() — the OpenAI classification call."""

    _VALID_CLASSIFICATION = {
        "urgency":          "High",
        "category":         "Complaint",
        "summary":          "Customer unhappy with delivery time.",
        "suggested_action": "Escalate to logistics team.",
    }

    def _mock_openai(self, content: str) -> MagicMock:
        """Return a mock client whose create() returns `content` as the message."""
        client = MagicMock()
        client.chat.completions.create.return_value = _make_openai_response(content)
        return client

    @patch("function_app._get_openai_client")
    def test_returns_parsed_classification(self, mock_getter):
        """Happy path — valid JSON returned by the model is parsed correctly."""
        mock_getter.return_value = self._mock_openai(json.dumps(self._VALID_CLASSIFICATION))

        result = function_app._classify_enquiry("alice@example.com", "Late delivery", "It's been 2 weeks.")

        self.assertEqual(result["urgency"],  "High")
        self.assertEqual(result["category"], "Complaint")
        self.assertIn("summary",          result)
        self.assertIn("suggested_action", result)

    @patch("function_app._get_openai_client")
    def test_passes_correct_model_and_format(self, mock_getter):
        """The create() call must use json_object response_format and low temperature."""
        client = self._mock_openai(json.dumps(self._VALID_CLASSIFICATION))
        mock_getter.return_value = client

        function_app._classify_enquiry("s", "sub", "body")

        _, kwargs = client.chat.completions.create.call_args
        self.assertEqual(kwargs["response_format"], {"type": "json_object"})
        self.assertLessEqual(kwargs["temperature"], 0.2)

    @patch("function_app._get_openai_client")
    def test_includes_sender_subject_body_in_prompt(self, mock_getter):
        """User message must contain sender, subject, and body text."""
        client = self._mock_openai(json.dumps(self._VALID_CLASSIFICATION))
        mock_getter.return_value = client

        function_app._classify_enquiry("bob@example.com", "Refund request", "I want my money back.")

        _, kwargs = client.chat.completions.create.call_args
        user_content = next(
            m["content"] for m in kwargs["messages"] if m["role"] == "user"
        )
        self.assertIn("bob@example.com",    user_content)
        self.assertIn("Refund request",     user_content)
        self.assertIn("I want my money back.", user_content)

    @patch("function_app._get_openai_client")
    def test_raises_on_invalid_json(self, mock_getter):
        """A non-JSON model response must raise (to trigger dead-lettering)."""
        mock_getter.return_value = self._mock_openai("not json at all")

        with self.assertRaises(json.JSONDecodeError):
            function_app._classify_enquiry("s", "sub", "body")

    @patch("function_app._get_openai_client")
    def test_raises_on_openai_error(self, mock_getter):
        """An SDK exception must propagate so the message is dead-lettered."""
        client = MagicMock()
        client.chat.completions.create.side_effect = RuntimeError("API unavailable")
        mock_getter.return_value = client

        with self.assertRaises(RuntimeError):
            function_app._classify_enquiry("s", "sub", "body")


# ─────────────────────────────────────────────────────────────────────────────
# TestBuildDocument
# ─────────────────────────────────────────────────────────────────────────────

class TestBuildDocument(unittest.TestCase):
    """Tests for _build_document() — pure function, no mocks needed."""

    def _build(self, **overrides) -> dict:
        defaults = dict(
            sender="alice@example.com",
            subject="Test subject",
            body="Test body",
            urgency="Medium",
            category="General",
            summary="A test enquiry.",
            suggested_action="Review.",
        )
        defaults.update(overrides)
        return function_app._build_document(**defaults)

    def test_has_all_required_fields(self):
        doc = self._build()
        for field in ("id", "dateKey", "timestamp", "sender", "subject",
                      "body", "urgency", "category", "summary",
                      "suggestedAction", "status"):
            self.assertIn(field, doc, f"Missing field: {field}")

    def test_status_is_open(self):
        self.assertEqual(self._build()["status"], "Open")

    def test_date_key_format(self):
        """dateKey must be YYYY-MM-DD (the Cosmos DB partition key)."""
        doc = self._build()
        datetime.strptime(doc["dateKey"], "%Y-%m-%d")  # raises on bad format

    def test_id_is_valid_uuid(self):
        import uuid
        doc = self._build()
        uuid.UUID(doc["id"])  # raises on invalid UUID

    def test_timestamp_is_iso_utc(self):
        doc = self._build()
        # Must be parseable and include UTC offset information
        dt = datetime.fromisoformat(doc["timestamp"])
        self.assertIsNotNone(dt.tzinfo)

    def test_fields_are_mapped_correctly(self):
        doc = self._build(
            sender="s@s.com",
            subject="Sub",
            body="Body",
            urgency="Critical",
            category="Complaint",
            summary="Sum",
            suggested_action="Act",
        )
        self.assertEqual(doc["sender"],          "s@s.com")
        self.assertEqual(doc["subject"],         "Sub")
        self.assertEqual(doc["body"],            "Body")
        self.assertEqual(doc["urgency"],         "Critical")
        self.assertEqual(doc["category"],        "Complaint")
        self.assertEqual(doc["summary"],         "Sum")
        self.assertEqual(doc["suggestedAction"], "Act")

    def test_each_call_produces_unique_id(self):
        ids = {self._build()["id"] for _ in range(10)}
        self.assertEqual(len(ids), 10)


# ─────────────────────────────────────────────────────────────────────────────
# TestPublishCriticalAlert
# ─────────────────────────────────────────────────────────────────────────────

class TestPublishCriticalAlert(unittest.TestCase):
    """Tests for _publish_critical_alert()."""

    @patch("function_app._get_eventgrid_client")
    def test_sends_event_with_correct_shape(self, mock_getter):
        """The published event must carry the correct type, subject, and data."""
        client = MagicMock()
        mock_getter.return_value = client

        function_app._publish_critical_alert(
            enquiry_id="abc-123",
            sender="bob@example.com",
            summary="Critical issue.",
            category="Complaint",
        )

        client.send.assert_called_once()
        events = client.send.call_args[0][0]
        self.assertEqual(len(events), 1)

        event = events[0]
        self.assertEqual(event.event_type, "EnquiryHub.Enquiry.Critical")
        self.assertEqual(event.subject,    "enquiries/abc-123")
        self.assertEqual(event.data["enquiry_id"], "abc-123")
        self.assertEqual(event.data["sender"],     "bob@example.com")
        self.assertEqual(event.data["category"],   "Complaint")

    @patch("function_app._get_eventgrid_client")
    def test_does_not_raise_on_eventgrid_error(self, mock_getter):
        """A failed Event Grid publish must NOT propagate — Cosmos write is more important."""
        client = MagicMock()
        client.send.side_effect = RuntimeError("Event Grid down")
        mock_getter.return_value = client

        # Should log the error but not raise
        try:
            function_app._publish_critical_alert("id", "sender", "summary", "category")
        except Exception as exc:  # noqa: BLE001
            self.fail(f"_publish_critical_alert raised unexpectedly: {exc}")


# ─────────────────────────────────────────────────────────────────────────────
# TestProcessEnquiryImpl
# ─────────────────────────────────────────────────────────────────────────────

class TestProcessEnquiryImpl(unittest.TestCase):
    """Tests for _process_enquiry_impl() — the core orchestration function."""

    _PAYLOAD = json.dumps(
        {"sender": "alice@example.com", "subject": "Help!", "body": "Something is wrong."}
    )

    def _classification(self, urgency: str = "Medium") -> dict:
        return {
            "urgency":          urgency,
            "category":         "Support",
            "summary":          "Customer needs help.",
            "suggested_action": "Assign to support.",
        }

    @patch("function_app._publish_critical_alert")
    @patch("function_app._get_cosmos_container")
    @patch("function_app._classify_enquiry")
    def test_upserts_document_to_cosmos(self, mock_classify, mock_cosmos_getter, mock_alert):
        mock_classify.return_value = self._classification()
        container = MagicMock()
        mock_cosmos_getter.return_value = container

        function_app._process_enquiry_impl(self._PAYLOAD)

        container.upsert_item.assert_called_once()
        doc = container.upsert_item.call_args[0][0]
        self.assertEqual(doc["sender"],  "alice@example.com")
        self.assertEqual(doc["subject"], "Help!")
        self.assertEqual(doc["status"],  "Open")

    @patch("function_app._publish_critical_alert")
    @patch("function_app._get_cosmos_container")
    @patch("function_app._classify_enquiry")
    def test_publishes_alert_for_critical(self, mock_classify, mock_cosmos_getter, mock_alert):
        """Critical urgency must trigger an Event Grid alert."""
        mock_classify.return_value = self._classification(urgency="Critical")
        mock_cosmos_getter.return_value = MagicMock()

        function_app._process_enquiry_impl(self._PAYLOAD)

        # _publish_critical_alert is called with (enquiry_id, sender, summary, category).
        # Urgency is not passed — the if-guard in _process_enquiry_impl already ensures
        # it is only called for Critical; assert_called_once() is sufficient here.
        mock_alert.assert_called_once()
        call_args = mock_alert.call_args[0]
        self.assertEqual(call_args[1], "alice@example.com")  # sender
        self.assertEqual(call_args[3], "Support")           # category

    @patch("function_app._publish_critical_alert")
    @patch("function_app._get_cosmos_container")
    @patch("function_app._classify_enquiry")
    def test_no_alert_for_non_critical(self, mock_classify, mock_cosmos_getter, mock_alert):
        """Non-Critical enquiries must NOT publish an Event Grid event."""
        for urgency in ("High", "Medium", "Low"):
            mock_alert.reset_mock()
            mock_classify.return_value = self._classification(urgency=urgency)
            mock_cosmos_getter.return_value = MagicMock()

            function_app._process_enquiry_impl(self._PAYLOAD)

            mock_alert.assert_not_called()

    @patch("function_app._get_cosmos_container")
    @patch("function_app._classify_enquiry")
    def test_reraises_on_classification_failure(self, mock_classify, mock_cosmos_getter):
        """A classification failure must propagate so the message is dead-lettered."""
        mock_classify.side_effect = RuntimeError("OpenAI timeout")
        mock_cosmos_getter.return_value = MagicMock()

        with self.assertRaises(RuntimeError):
            function_app._process_enquiry_impl(self._PAYLOAD)

    @patch("function_app._publish_critical_alert")
    @patch("function_app._get_cosmos_container")
    @patch("function_app._classify_enquiry")
    def test_uses_defaults_for_missing_payload_fields(self, mock_classify, mock_cosmos_getter, mock_alert):
        """Missing sender/subject/body in the message must not raise — use defaults."""
        mock_classify.return_value = self._classification()
        container = MagicMock()
        mock_cosmos_getter.return_value = container

        function_app._process_enquiry_impl(json.dumps({}))  # empty payload

        doc = container.upsert_item.call_args[0][0]
        self.assertEqual(doc["sender"],  "unknown")
        self.assertEqual(doc["subject"], "(no subject)")
        self.assertEqual(doc["body"],    "")

    @patch("function_app._publish_critical_alert")
    @patch("function_app._get_cosmos_container")
    @patch("function_app._classify_enquiry")
    def test_classification_fields_stored_in_document(self, mock_classify, mock_cosmos_getter, mock_alert):
        """Classification output must be faithfully written to the Cosmos document."""
        mock_classify.return_value = {
            "urgency":          "High",
            "category":         "Quote Request",
            "summary":          "Customer wants a quote.",
            "suggested_action": "Send pricing.",
        }
        container = MagicMock()
        mock_cosmos_getter.return_value = container

        function_app._process_enquiry_impl(self._PAYLOAD)

        doc = container.upsert_item.call_args[0][0]
        self.assertEqual(doc["urgency"],         "High")
        self.assertEqual(doc["category"],        "Quote Request")
        self.assertEqual(doc["summary"],         "Customer wants a quote.")
        self.assertEqual(doc["suggestedAction"], "Send pricing.")


# ─────────────────────────────────────────────────────────────────────────────
# TestSubmitEnquiry
# ─────────────────────────────────────────────────────────────────────────────

class TestSubmitEnquiry(unittest.TestCase):
    """Tests for the submit_enquiry HTTP handler."""

    _VALID_BODY = {"sender": "alice@example.com", "subject": "Help", "body": "I need help."}

    @patch("function_app._send_enquiry")
    def test_returns_202_on_valid_request(self, mock_send):
        req = _make_http_request(self._VALID_BODY)
        resp = function_app.submit_enquiry(req)

        self.assertEqual(resp.status_code, 202)
        data = json.loads(resp.get_body())
        self.assertIn("message_id", data)
        self.assertEqual(data["status"], "queued")

    @patch("function_app._send_enquiry")
    def test_calls_send_with_json_payload(self, mock_send):
        """The full payload must be forwarded to the queue, not just a subset."""
        req = _make_http_request(self._VALID_BODY)
        function_app.submit_enquiry(req)

        mock_send.assert_called_once()
        sent = json.loads(mock_send.call_args[0][0])
        self.assertEqual(sent["sender"],  self._VALID_BODY["sender"])
        self.assertEqual(sent["subject"], self._VALID_BODY["subject"])
        self.assertEqual(sent["body"],    self._VALID_BODY["body"])

    def test_returns_400_on_invalid_json(self):
        req = _make_http_request("not json at all")
        resp = function_app.submit_enquiry(req)
        self.assertEqual(resp.status_code, 400)

    def test_returns_400_when_sender_missing(self):
        body = {k: v for k, v in self._VALID_BODY.items() if k != "sender"}
        req = _make_http_request(body)
        resp = function_app.submit_enquiry(req)
        self.assertEqual(resp.status_code, 400)
        self.assertIn("sender", resp.get_body().decode())

    def test_returns_400_when_subject_missing(self):
        body = {k: v for k, v in self._VALID_BODY.items() if k != "subject"}
        req = _make_http_request(body)
        resp = function_app.submit_enquiry(req)
        self.assertEqual(resp.status_code, 400)

    def test_returns_400_when_body_missing(self):
        body = {k: v for k, v in self._VALID_BODY.items() if k != "body"}
        req = _make_http_request(body)
        resp = function_app.submit_enquiry(req)
        self.assertEqual(resp.status_code, 400)

    def test_returns_400_when_all_fields_missing(self):
        req = _make_http_request({})
        resp = function_app.submit_enquiry(req)
        self.assertEqual(resp.status_code, 400)

    @patch("function_app._send_enquiry")
    def test_each_call_produces_unique_message_id(self, mock_send):
        """Multiple submissions must each get a distinct message_id."""
        ids = set()
        for _ in range(5):
            req = _make_http_request(self._VALID_BODY)
            resp = function_app.submit_enquiry(req)
            ids.add(json.loads(resp.get_body())["message_id"])
        self.assertEqual(len(ids), 5)

    @patch("function_app._send_enquiry")
    def test_response_content_type_is_json(self, mock_send):
        req = _make_http_request(self._VALID_BODY)
        resp = function_app.submit_enquiry(req)
        self.assertIn("application/json", resp.mimetype)


# ─────────────────────────────────────────────────────────────────────────────
# TestChatEndpoint
# ─────────────────────────────────────────────────────────────────────────────

class TestChatEndpoint(unittest.TestCase):
    """Tests for the chat_endpoint HTTP handler."""

    _SAMPLE_ITEMS = [
        {"id": "1", "dateKey": "2025-01-01", "sender": "a@b.com",
         "subject": "Issue", "urgency": "High", "category": "Support",
         "summary": "Customer has an issue.", "status": "Open"},
    ]

    def _mock_cosmos(self, items: list) -> MagicMock:
        container = MagicMock()
        container.query_items.return_value = iter(items)
        return container

    def _mock_openai(self, answer: str) -> MagicMock:
        return MagicMock(**{"chat.completions.create.return_value": _make_openai_response(answer)})

    @patch("function_app._get_openai_client")
    @patch("function_app._get_cosmos_container")
    def test_returns_200_with_answer(self, mock_cosmos_getter, mock_openai_getter):
        mock_cosmos_getter.return_value = self._mock_cosmos(self._SAMPLE_ITEMS)
        mock_openai_getter.return_value = self._mock_openai("There is 1 open enquiry.")

        req = _make_http_request({"question": "How many open enquiries?"})
        resp = function_app.chat_endpoint(req)

        self.assertEqual(resp.status_code, 200)
        data = json.loads(resp.get_body())
        self.assertEqual(data["answer"], "There is 1 open enquiry.")

    @patch("function_app._get_openai_client")
    @patch("function_app._get_cosmos_container")
    def test_queries_cosmos_with_cross_partition(self, mock_cosmos_getter, mock_openai_getter):
        """The Cosmos query must have enable_cross_partition_query=True."""
        container = self._mock_cosmos([])
        mock_cosmos_getter.return_value = container
        mock_openai_getter.return_value = self._mock_openai("No data.")

        req = _make_http_request({"question": "Any recent complaints?"})
        function_app.chat_endpoint(req)

        _, kwargs = container.query_items.call_args
        self.assertTrue(kwargs.get("enable_cross_partition_query"))

    @patch("function_app._get_openai_client")
    @patch("function_app._get_cosmos_container")
    def test_passes_cosmos_data_and_question_to_openai(self, mock_cosmos_getter, mock_openai_getter):
        """The OpenAI user message must include both the enquiry data and the question."""
        container = self._mock_cosmos(self._SAMPLE_ITEMS)
        mock_cosmos_getter.return_value = container
        client = self._mock_openai("Answer.")
        mock_openai_getter.return_value = client

        req = _make_http_request({"question": "Who sent a complaint?"})
        function_app.chat_endpoint(req)

        _, kwargs = client.chat.completions.create.call_args
        user_msg = next(m["content"] for m in kwargs["messages"] if m["role"] == "user")
        self.assertIn("Who sent a complaint?", user_msg)
        self.assertIn("a@b.com", user_msg)  # Cosmos data present in context

    @patch("function_app._get_openai_client")
    @patch("function_app._get_cosmos_container")
    def test_uses_low_temperature(self, mock_cosmos_getter, mock_openai_getter):
        """Temperature should be <= 0.5 to keep answers grounded in the data."""
        mock_cosmos_getter.return_value = self._mock_cosmos([])
        client = self._mock_openai("Answer.")
        mock_openai_getter.return_value = client

        req = _make_http_request({"question": "Q?"})
        function_app.chat_endpoint(req)

        _, kwargs = client.chat.completions.create.call_args
        self.assertLessEqual(kwargs["temperature"], 0.5)

    def test_returns_400_on_invalid_json(self):
        req = _make_http_request("not json")
        resp = function_app.chat_endpoint(req)
        self.assertEqual(resp.status_code, 400)

    def test_returns_400_when_question_missing(self):
        req = _make_http_request({})
        resp = function_app.chat_endpoint(req)
        self.assertEqual(resp.status_code, 400)

    def test_returns_400_when_question_is_blank(self):
        req = _make_http_request({"question": "   "})
        resp = function_app.chat_endpoint(req)
        self.assertEqual(resp.status_code, 400)

    @patch("function_app._get_openai_client")
    @patch("function_app._get_cosmos_container")
    def test_response_content_type_is_json(self, mock_cosmos_getter, mock_openai_getter):
        mock_cosmos_getter.return_value = self._mock_cosmos([])
        mock_openai_getter.return_value = self._mock_openai("Answer.")

        req = _make_http_request({"question": "Q?"})
        resp = function_app.chat_endpoint(req)
        self.assertIn("application/json", resp.mimetype)


# ─────────────────────────────────────────────────────────────────────────────
# TestSendToServiceBus
# ─────────────────────────────────────────────────────────────────────────────

class TestSendToServiceBus(unittest.TestCase):
    """Tests for _send_to_service_bus() — SDK interaction."""

    @patch("function_app._get_credential")
    @patch("function_app.ServiceBusClient")
    def test_sends_message_to_correct_queue(self, mock_sb_class, mock_cred_getter):
        """Message must be sent to SERVICE_BUS_QUEUE with the correct body."""
        # Build the mock context manager chain:
        # ServiceBusClient(...).__enter__().get_queue_sender(...).__enter__().send_messages(...)
        sender = MagicMock()
        queue_sender_ctx = MagicMock()
        queue_sender_ctx.__enter__ = MagicMock(return_value=sender)
        queue_sender_ctx.__exit__ = MagicMock(return_value=False)

        sb_client = MagicMock()
        sb_client.get_queue_sender.return_value = queue_sender_ctx

        sb_ctx = MagicMock()
        sb_ctx.__enter__ = MagicMock(return_value=sb_client)
        sb_ctx.__exit__ = MagicMock(return_value=False)

        mock_sb_class.return_value = sb_ctx
        mock_cred_getter.return_value = MagicMock()

        function_app._send_to_service_bus('{"sender": "a@b.com"}')

        # Verify queue name
        sb_client.get_queue_sender.assert_called_once_with(queue_name="enquiry-queue")
        # Verify a message was sent
        sender.send_messages.assert_called_once()

    @patch("function_app._get_credential")
    @patch("function_app.ServiceBusClient")
    def test_uses_managed_identity_not_connection_string(self, mock_sb_class, mock_cred_getter):
        """ServiceBusClient must be constructed with fully_qualified_namespace, not conn_str."""
        # Wire up context manager chain (minimal)
        sender = MagicMock()
        queue_ctx = MagicMock()
        queue_ctx.__enter__ = MagicMock(return_value=sender)
        queue_ctx.__exit__ = MagicMock(return_value=False)
        sb_client = MagicMock()
        sb_client.get_queue_sender.return_value = queue_ctx
        sb_ctx = MagicMock()
        sb_ctx.__enter__ = MagicMock(return_value=sb_client)
        sb_ctx.__exit__ = MagicMock(return_value=False)
        mock_sb_class.return_value = sb_ctx
        mock_cred_getter.return_value = MagicMock()

        function_app._send_to_service_bus("{}")

        _, kwargs = mock_sb_class.call_args
        self.assertIn("fully_qualified_namespace", kwargs)
        self.assertNotIn("conn_str", kwargs)
        self.assertNotIn("connection_string", kwargs)


# ─────────────────────────────────────────────────────────────────────────────
# TestSendToStorageQueue
# ─────────────────────────────────────────────────────────────────────────────

class TestSendToStorageQueue(unittest.TestCase):
    """Tests for _send_to_storage_queue() — base64 encoding + SDK interaction."""

    @patch("function_app.QueueClient")
    def test_base64_encodes_message(self, mock_qclient_class):
        """Message body must be base64-encoded before sending."""
        client = MagicMock()
        mock_qclient_class.from_connection_string.return_value = client

        payload = '{"sender": "a@b.com"}'
        function_app._send_to_storage_queue(payload)

        client.send_message.assert_called_once()
        sent = client.send_message.call_args[0][0]
        # Decode and verify the content round-trips correctly
        decoded = base64.b64decode(sent).decode()
        self.assertEqual(decoded, payload)

    @patch("function_app.QueueClient")
    def test_sends_to_correct_queue(self, mock_qclient_class):
        """The queue name must be 'enquiry-queue'."""
        client = MagicMock()
        mock_qclient_class.from_connection_string.return_value = client

        function_app._send_to_storage_queue("{}")

        _, queue_name = mock_qclient_class.from_connection_string.call_args[0]
        self.assertEqual(queue_name, "enquiry-queue")


if __name__ == "__main__":
    unittest.main()
