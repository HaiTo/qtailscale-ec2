"""Start the exit-node EC2 instance when called from an iPhone shortcut."""

import hmac
import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

INSTANCE_ID = os.environ["INSTANCE_ID"]
TOKEN_PARAMETER_NAME = os.environ["TOKEN_PARAMETER_NAME"]
TOKEN_HEADER = "x-auth-token"  # Function URLs pass header names in lowercase

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def _forbidden(source_ip, reason):
    # Never log the token itself
    logger.warning("forbidden: reason=%s source_ip=%s", reason, source_ip)
    return _response(403, {"error": "forbidden"})


def handler(event, context):
    http = event.get("requestContext", {}).get("http", {})
    source_ip = http.get("sourceIp")

    if http.get("method") != "POST":
        return _response(405, {"error": "method not allowed"})

    provided = (event.get("headers") or {}).get(TOKEN_HEADER, "")
    if not provided:
        return _forbidden(source_ip, "missing token")

    # Fetched on every call so a rotated token takes effect immediately
    expected = ssm.get_parameter(Name=TOKEN_PARAMETER_NAME, WithDecryption=True)[
        "Parameter"
    ]["Value"]

    # Comparing bytes keeps this constant-time and safe for non-ASCII input
    if not expected or not hmac.compare_digest(
        provided.encode("utf-8"), expected.encode("utf-8")
    ):
        return _forbidden(source_ip, "token mismatch")

    try:
        result = ec2.start_instances(InstanceIds=[INSTANCE_ID])
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "IncorrectInstanceState":
            # Typically still stopping; a retry shortly afterwards succeeds
            logger.info("instance not startable yet: source_ip=%s", source_ip)
            return _response(409, {"error": "instance is stopping, retry shortly"})
        logger.error("start_instances failed: code=%s", code)
        return _response(500, {"error": "failed to start instance"})

    state = result["StartingInstances"][0]
    previous = state["PreviousState"]["Name"]
    current = state["CurrentState"]["Name"]
    logger.info(
        "start requested: previous=%s current=%s source_ip=%s",
        previous,
        current,
        source_ip,
    )
    return _response(200, {"previous": previous, "current": current})
