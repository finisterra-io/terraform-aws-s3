/**
 * # AWS S3 Bucket Management with Terraform Module
 * 
 * This Terraform module for AWS S3 equips engineers with a robust toolkit for automating the configuration and management of AWS S3 buckets. Tailored for scalability and flexibility, it is designed to cater to a wide array of storage needs, from simple setups to complex infrastructures.
 * ## Usage
 * 
 * If you want your code in minutes and not in days, you can use [finisterra](https://finisterra.io), and it will simply read your S3 buckets and generate the code necessary to call this module.
 * 
 * Here is how to do it:
 * 
 * ```bash
 * pip install finisterra
 * finisterra -p aws -m aws
 * ```
 * 
 * ## Key Features:
 * 
 * - **Comprehensive Bucket Configuration**: Control over access policies, encryption, CORS, versioning, and more.
 * - **Security and Compliance**: Features to enforce policies on encryption headers, block public access, and manage object ownership.
 * - **Lifecycle Management**: Automation of lifecycle rules for efficient storage management.
 * - **Logging and Monitoring**: Configuration of bucket logging and metrics for improved visibility and auditing.
 * - **Cross-Region Replication**: Support for replication configuration to meet disaster recovery and data locality requirements.
 * - **Flexible Input and Output Options**: Extensive inputs for custom configurations and detailed outputs for resource management.
 */
data "aws_caller_identity" "current" {}
locals {
  create_bucket = var.create_bucket

  attach_policy = var.attach_require_latest_tls_policy || var.attach_elb_log_delivery_policy || var.attach_lb_log_delivery_policy || var.attach_deny_insecure_transport_policy || var.attach_inventory_destination_policy || var.attach_deny_incorrect_encryption_headers || var.attach_deny_incorrect_kms_key_sse || var.attach_deny_unencrypted_object_uploads || var.attach_policy

  grants               = try(jsondecode(var.grant), var.grant)
  cors_rules           = try(jsondecode(var.cors_rule), var.cors_rule)
  metric_configuration = try(jsondecode(var.metric_configuration), var.metric_configuration)
}

resource "aws_s3_bucket" "this" {
  count = local.create_bucket ? 1 : 0

  bucket        = var.bucket
  bucket_prefix = var.bucket_prefix

  force_destroy       = var.force_destroy
  object_lock_enabled = var.object_lock_enabled
  tags                = var.tags
}

resource "aws_s3_bucket_logging" "this" {
  count = local.create_bucket && var.logging != null ? 1 : 0

  bucket = aws_s3_bucket.this[0].id

  target_bucket = var.logging.target_bucket
  target_prefix = try(var.logging.target_prefix, "")

  dynamic "target_object_key_format" {
    for_each = lookup(var.logging, "target_object_key_format", null) != null ? var.logging.target_object_key_format : []

    content {
      dynamic "partitioned_prefix" {
        for_each = try(target_object_key_format.value.partitioned_prefix, [])

        content {
          partition_date_source = partitioned_prefix.value.partition_date_source
        }
      }

      dynamic "simple_prefix" {
        for_each = try(target_object_key_format.value.simple_prefix, [])

        content {
        }
      }
    }
  }
}

resource "aws_s3_bucket_acl" "this" {
  count = local.create_bucket && ((var.acl != null && var.acl != "null") || length(local.grants) > 0) ? 1 : 0

  bucket                = aws_s3_bucket.this[0].id
  expected_bucket_owner = var.expected_bucket_owner

  acl = var.acl == "null" ? null : var.acl

  dynamic "access_control_policy" {
    for_each = length(local.grants) > 0 ? [true] : []

    content {
      dynamic "grant" {
        for_each = local.grants

        content {
          permission = grant.value.permission

          grantee {
            type          = grant.value.type
            id            = try(grant.value.id, data.aws_canonical_user_id.this.id)
            uri           = try(grant.value.uri, null)
            email_address = try(grant.value.email, null)
          }
        }
      }

      owner {
        id           = try(var.owner["id"], data.aws_canonical_user_id.this.id)
        display_name = try(var.owner["display_name"], null)
      }
    }
  }

  depends_on = [aws_s3_bucket_ownership_controls.this]
}

resource "aws_s3_bucket_website_configuration" "this" {
  count = local.create_bucket && length(keys(var.website)) > 0 ? 1 : 0

  bucket                = aws_s3_bucket.this[0].id
  expected_bucket_owner = var.expected_bucket_owner

  dynamic "index_document" {
    for_each = try([var.website["index_document"]], [])

    content {
      suffix = index_document.value
    }
  }

  dynamic "error_document" {
    for_each = try([var.website["error_document"]], [])

    content {
      key = error_document.value
    }
  }

  dynamic "redirect_all_requests_to" {
    for_each = try([var.website["redirect_all_requests_to"]], [])

    content {
      host_name = redirect_all_requests_to.value.host_name
      protocol  = redirect_all_requests_to.value.protocol != "" ? redirect_all_requests_to.value.protocol : null
    }
  }

  dynamic "routing_rule" {
    for_each = try(var.website["routing_rules"], [])

    content {
      dynamic "condition" {
        for_each = routing_rule.value.condition

        content {
          http_error_code_returned_equals = try(condition.value.http_error_code_returned_equals, null)
          key_prefix_equals               = try(condition.value.key_prefix_equals, null)
        }
      }

      redirect {
        host_name               = try(routing_rule.value.redirect[0]["host_name"], null)
        http_redirect_code      = try(routing_rule.value.redirect[0]["http_redirect_code"], null)
        protocol                = try(routing_rule.value.redirect[0]["protocol"], null)
        replace_key_prefix_with = try(routing_rule.value.redirect[0]["replace_key_prefix_with"], null)
        replace_key_with        = try(routing_rule.value.redirect[0]["replace_key_with"], null)
      }
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  count = local.create_bucket && length(keys(var.versioning)) > 0 ? 1 : 0

  bucket                = aws_s3_bucket.this[0].id
  expected_bucket_owner = var.expected_bucket_owner
  mfa                   = try(var.versioning["mfa"], null)

  versioning_configuration {
    status = try(var.versioning["enabled"] ? "Enabled" : "Suspended", tobool(var.versioning["status"]) ? "Enabled" : "Suspended", title(lower(var.versioning["status"])))

    mfa_delete = try(tobool(var.versioning["mfa_delete"]) ? "Enabled" : "Disabled", title(lower(var.versioning["mfa_delete"])), null)
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  count = local.create_bucket && length(keys(var.server_side_encryption_configuration)) > 0 ? 1 : 0

  bucket                = aws_s3_bucket.this[0].id
  expected_bucket_owner = var.expected_bucket_owner

  dynamic "rule" {
    for_each = try(flatten([var.server_side_encryption_configuration["rule"]]), [])

    content {
      bucket_key_enabled = try(rule.value.bucket_key_enabled, null)

      dynamic "apply_server_side_encryption_by_default" {
        for_each = try([rule.value.apply_server_side_encryption_by_default], [])

        content {
          sse_algorithm     = apply_server_side_encryption_by_default.value.sse_algorithm
          kms_master_key_id = try(apply_server_side_encryption_by_default.value.kms_master_key_id, null)
        }
      }
    }
  }
}

resource "aws_s3_bucket_accelerate_configuration" "this" {
  count = local.create_bucket && var.acceleration_status != null ? 1 : 0

  bucket                = aws_s3_bucket.this[0].id
  expected_bucket_owner = var.expected_bucket_owner

  status = title(lower(var.acceleration_status))
}

resource "aws_s3_bucket_request_payment_configuration" "this" {
  count = local.create_bucket && var.request_payer != null ? 1 : 0

  bucket                = aws_s3_bucket.this[0].id
  expected_bucket_owner = var.expected_bucket_owner

  payer = lower(var.request_payer) == "requester" ? "Requester" : "BucketOwner"
}

resource "aws_s3_bucket_cors_configuration" "this" {
  count = local.create_bucket && length(local.cors_rules) > 0 ? 1 : 0

  bucket                = aws_s3_bucket.this[0].id
  expected_bucket_owner = var.expected_bucket_owner

  dynamic "cors_rule" {
    for_each = local.cors_rules

    content {
      id              = try(cors_rule.value.id, null)
      allowed_methods = cors_rule.value.allowed_methods
      allowed_origins = cors_rule.value.allowed_origins
      allowed_headers = try(cors_rule.value.allowed_headers, null)
      expose_headers  = try(cors_rule.value.expose_headers, null)
      max_age_seconds = try(cors_rule.value.max_age_seconds, null)
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count = local.create_bucket && length(var.lifecycle_rule) > 0 ? 1 : 0

  bucket                = aws_s3_bucket.this[0].id
  expected_bucket_owner = var.expected_bucket_owner

  dynamic "rule" {
    for_each = var.lifecycle_rule

    content {
      id     = try(rule.value.id, null)
      status = try(rule.value.enabled ? "Enabled" : "Disabled", tobool(rule.value.status) ? "Enabled" : "Disabled", title(lower(rule.value.status)))

      # Max 1 block - abort_incomplete_multipart_upload
      dynamic "abort_incomplete_multipart_upload" {
        for_each = try(flatten([rule.value.abort_incomplete_multipart_upload]), [])

        content {
          days_after_initiation = try(abort_incomplete_multipart_upload.value.days_after_initiation, null)
        }
      }


      # Max 1 block - expiration
      dynamic "expiration" {
        for_each = try(flatten([rule.value.expiration]), [])

        content {
          date                         = try(expiration.value.date, null)
          days                         = try(expiration.value.days, null)
          expired_object_delete_marker = try(expiration.value.expired_object_delete_marker, null)
        }
      }

      # Several blocks - transition
      dynamic "transition" {
        for_each = try(flatten([rule.value.transition]), [])

        content {
          date          = try(transition.value.date, null)
          days          = try(transition.value.days, null)
          storage_class = transition.value.storage_class
        }
      }

      # Max 1 block - noncurrent_version_expiration
      dynamic "noncurrent_version_expiration" {
        for_each = try(flatten([rule.value.noncurrent_version_expiration]), [])

        content {
          newer_noncurrent_versions = try(noncurrent_version_expiration.value.newer_noncurrent_versions, null)
          noncurrent_days           = try(noncurrent_version_expiration.value.days, noncurrent_version_expiration.value.noncurrent_days, null)
        }
      }

      # Several blocks - noncurrent_version_transition
      dynamic "noncurrent_version_transition" {
        for_each = try(flatten([rule.value.noncurrent_version_transition]), [])

        content {
          newer_noncurrent_versions = try(noncurrent_version_transition.value.newer_noncurrent_versions, null)
          noncurrent_days           = try(noncurrent_version_transition.value.days, noncurrent_version_transition.value.noncurrent_days, null)
          storage_class             = noncurrent_version_transition.value.storage_class
        }
      }

      # Max 1 block - filter - with one key argument, a single tag, or a prefix
      dynamic "filter" {
        for_each = [
          for v in try(rule.value.filter, []) :
          v if length(keys(v)) == 1 && contains(keys(v), "prefix") || (length(try(v.tags, {})) == 1 || length(try(v.tag, [])) == 1)
        ]

        content {
          object_size_greater_than = try(filter.value.object_size_greater_than, null)
          object_size_less_than    = try(filter.value.object_size_less_than, null)
          prefix                   = try(filter.value.prefix, null)

          dynamic "tag" {
            for_each = try(filter.value.tags, filter.value.tag, [])

            content {
              key   = tag.key
              value = tag.value
            }
          }
        }
      }

      dynamic "filter" {
        for_each = [
          for filter in try(rule.value.filter, []) :
          filter if length(keys(filter)) == 1 && try(length(keys(filter.and[0])) > 0, false)
        ]

        content {
          and {
            object_size_greater_than = try(filter.value.and[0].object_size_greater_than, null)
            object_size_less_than    = try(filter.value.and[0].object_size_less_than, null)
            prefix                   = try(filter.value.and[0].prefix, null)
            tags                     = try(filter.value.and[0].tags, null)
          }
        }
      }
    }
  }

  # Must have bucket versioning enabled first
  depends_on = [aws_s3_bucket_versioning.this]
}


resource "aws_s3_bucket_object_lock_configuration" "this" {
  count = local.create_bucket && var.create_object_lock_configuration ? 1 : 0

  bucket                = aws_s3_bucket.this[0].id
  expected_bucket_owner = var.expected_bucket_owner
  token                 = var.object_lock_configuration_token
  object_lock_enabled   = var.object_lock_configuration_object_lock_enabled


  dynamic "rule" {
    for_each = var.object_lock_configuration_rule

    content {
      default_retention {
        mode  = rule.value.default_retention.mode
        days  = rule.value.default_retention.days > 0 ? rule.value.default_retention.days : null
        years = rule.value.default_retention.years > 0 ? rule.value.default_retention.years : null
      }
    }
  }
}


resource "aws_s3_bucket_replication_configuration" "this" {
  count = local.create_bucket && length(keys(var.replication_configuration)) > 0 ? 1 : 0

  bucket = aws_s3_bucket.this[0].id
  role   = var.replication_configuration["role"]

  dynamic "rule" {
    for_each = flatten(try([var.replication_configuration["rule"]], [var.replication_configuration["rules"]], []))

    content {
      id       = try(rule.value.id, null)
      priority = try(rule.value.priority, null)
      # prefix   = try(rule.value.prefix, null)
      status = try(tobool(rule.value.status) ? "Enabled" : "Disabled", title(lower(rule.value.status)), "Enabled")

      dynamic "delete_marker_replication" {
        for_each = flatten(try([rule.value.delete_marker_replication_status], [rule.value.delete_marker_replication], []))

        content {
          # Valid values: "Enabled" or "Disabled"
          status = try(tobool(delete_marker_replication.value) ? "Enabled" : "Disabled", title(lower(delete_marker_replication.value)))
        }
      }

      # Amazon S3 does not support this argument according to:
      # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_replication_configuration
      # More infor about what does Amazon S3 replicate?
      # https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-what-is-isnot-replicated.html
      dynamic "existing_object_replication" {
        for_each = flatten(try([rule.value.existing_object_replication_status], [rule.value.existing_object_replication], []))

        content {
          # Valid values: "Enabled" or "Disabled"
          status = try(tobool(existing_object_replication.value) ? "Enabled" : "Disabled", title(lower(existing_object_replication.value)))
        }
      }

      dynamic "destination" {
        for_each = try(flatten([rule.value.destination]), [])

        content {
          bucket        = destination.value.bucket
          storage_class = try(destination.value.storage_class, null)
          account       = try(destination.value.account_id, destination.value.account, null)

          dynamic "access_control_translation" {
            for_each = try(flatten([destination.value.access_control_translation]), [])

            content {
              owner = title(lower(access_control_translation.value.owner))
            }
          }

          dynamic "encryption_configuration" {
            for_each = flatten([try(destination.value.encryption_configuration.replica_kms_key_id, destination.value.replica_kms_key_id, [])])

            content {
              replica_kms_key_id = encryption_configuration.value
            }
          }

          dynamic "replication_time" {
            for_each = try(flatten([destination.value.replication_time]), [])

            content {
              # Valid values: "Enabled" or "Disabled"
              status = try(tobool(replication_time.value.status) ? "Enabled" : "Disabled", title(lower(replication_time.value.status)), "Disabled")

              dynamic "time" {
                for_each = try(flatten([replication_time.value.minutes]), [])

                content {
                  minutes = replication_time.value.minutes
                }
              }
            }

          }

          dynamic "metrics" {
            for_each = try(flatten([destination.value.metrics]), [])

            content {
              # Valid values: "Enabled" or "Disabled"
              status = try(tobool(metrics.value.status) ? "Enabled" : "Disabled", title(lower(metrics.value.status)), "Disabled")

              dynamic "event_threshold" {
                for_each = try(flatten([metrics.value.minutes]), [])

                content {
                  minutes = metrics.value.minutes
                }
              }
            }
          }
        }
      }

      dynamic "source_selection_criteria" {
        for_each = try(flatten([rule.value.source_selection_criteria]), [])

        content {
          dynamic "replica_modifications" {
            for_each = flatten([try(source_selection_criteria.value.replica_modifications.enabled, source_selection_criteria.value.replica_modifications.status, [])])

            content {
              # Valid values: "Enabled" or "Disabled"
              status = try(tobool(replica_modifications.value) ? "Enabled" : "Disabled", title(lower(replica_modifications.value)), "Disabled")
            }
          }

          dynamic "sse_kms_encrypted_objects" {
            for_each = flatten([try(source_selection_criteria.value.sse_kms_encrypted_objects.enabled, source_selection_criteria.value.sse_kms_encrypted_objects.status, [])])

            content {
              # Valid values: "Enabled" or "Disabled"
              status = try(tobool(sse_kms_encrypted_objects.value) ? "Enabled" : "Disabled", title(lower(sse_kms_encrypted_objects.value)), "Disabled")
            }
          }
        }
      }

      # Max 1 block - filter - with one key argument or a single tag
      dynamic "filter" {
        for_each = [for v in try(flatten([rule.value.filter]), []) : v if max(length(keys(v)), length(try(rule.value.filter.tags, rule.value.filter.tag, []))) == 1]

        content {
          prefix = try(filter.value.prefix, null)

          dynamic "tag" {
            for_each = try(filter.value.tags, filter.value.tag, [])

            content {
              key   = tag.key
              value = tag.value
            }
          }
        }
      }

      # Max 1 block - filter - with more than one key arguments or multiple tags
      dynamic "filter" {
        for_each = [for v in try(flatten([rule.value.filter]), []) : v if max(length(keys(v)), length(try(rule.value.filter.tags, rule.value.filter.tag, []))) > 1]

        content {
          and {
            prefix = try(filter.value.prefix, null)
            tags   = try(filter.value.tags, filter.value.tag, null)
          }
        }
      }
    }
  }

  # Must have bucket versioning enabled first
  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_policy" "this" {
  count = local.create_bucket && local.attach_policy ? 1 : 0

  # Chain resources (s3_bucket -> s3_bucket_public_access_block -> s3_bucket_policy )
  # to prevent "A conflicting conditional operation is currently in progress against this resource."
  # Ref: https://github.com/hashicorp/terraform-provider-aws/issues/7628

  bucket = aws_s3_bucket.this[0].id
  policy = var.policy

  depends_on = [
    aws_s3_bucket_public_access_block.this
  ]
}


resource "aws_s3_bucket_public_access_block" "this" {
  count = local.create_bucket && var.attach_public_policy ? 1 : 0

  bucket = aws_s3_bucket.this[0].id

  block_public_acls       = var.block_public_acls
  block_public_policy     = var.block_public_policy
  ignore_public_acls      = var.ignore_public_acls
  restrict_public_buckets = var.restrict_public_buckets
}

resource "aws_s3_bucket_ownership_controls" "this" {
  count = local.create_bucket && var.control_object_ownership ? 1 : 0

  bucket = local.attach_policy ? aws_s3_bucket_policy.this[0].id : aws_s3_bucket.this[0].id

  rule {
    object_ownership = var.object_ownership
  }

  # This `depends_on` is to prevent "A conflicting conditional operation is currently in progress against this resource."
  depends_on = [
    aws_s3_bucket_policy.this,
    aws_s3_bucket_public_access_block.this,
    aws_s3_bucket.this
  ]
}

resource "aws_s3_bucket_intelligent_tiering_configuration" "this" {
  for_each = local.create_bucket ? var.intelligent_tiering : {}

  name   = each.key
  bucket = aws_s3_bucket.this[0].id
  status = each.value.status

  # Max 1 block - filter
  dynamic "filter" {
    for_each = lookup(each.value, "filter", null) != null ? each.value.filter : []

    content {
      prefix = try(filter.value.prefix, null)
      tags   = try(filter.value.tags, null)
    }
  }

  dynamic "tiering" {
    for_each = each.value.tiering

    content {
      access_tier = tiering.value.access_tier
      days        = tiering.value.days
    }
  }
}

resource "aws_s3_bucket_metric" "this" {
  for_each = { for k, v in local.metric_configuration : k => v if local.create_bucket }

  name   = each.value.name
  bucket = aws_s3_bucket.this[0].id

  dynamic "filter" {
    for_each = length(try(flatten([each.value.filter]), [])) == 0 ? [] : [true]
    content {
      prefix = try(each.value.filter.prefix, null)
      tags   = try(each.value.filter.tags, null)
    }
  }
}

resource "aws_s3_bucket_inventory" "this" {
  for_each = { for k, v in var.inventory_configuration : k => v if local.create_bucket }

  name                     = each.key
  bucket                   = try(each.value.bucket, aws_s3_bucket.this[0].id)
  included_object_versions = each.value.included_object_versions
  enabled                  = try(each.value.enabled, true)
  optional_fields          = try(each.value.optional_fields, null)

  destination {
    bucket {
      bucket_arn = try(each.value.destination.bucket_arn, aws_s3_bucket.this[0].arn)
      format     = try(each.value.destination.format, null)
      account_id = try(each.value.destination.account_id, null)
      prefix     = try(each.value.destination.prefix, null)

      dynamic "encryption" {
        for_each = length(try(each.value.destination.encryption, [])) == 0 ? [] : [true]

        content {

          dynamic "sse_kms" {
            for_each = each.value.destination.encryption[0].encryption_type == "sse_kms" ? [true] : []

            content {
              key_id = try(each.value.destination.encryption[0].kms_key_id, null)
            }
          }

          dynamic "sse_s3" {
            for_each = each.value.destination.encryption[0].encryption_type == "sse_s3" ? [true] : []

            content {
            }
          }
        }
      }
    }
  }

  schedule {
    frequency = each.value.frequency
  }

  dynamic "filter" {
    for_each = length(try(each.value.filter, [])) == 0 ? [] : [true]

    content {
      prefix = try(each.value.filter[0].prefix, null)
    }
  }
}

resource "aws_s3_bucket_analytics_configuration" "this" {
  for_each = { for k, v in var.analytics_configuration : k => v if local.create_bucket }

  bucket = aws_s3_bucket.this[0].id
  name   = each.key

  dynamic "filter" {
    for_each = each.value.filter

    content {
      prefix = try(filter.value.prefix, null)
      tags   = try(filter.value.tags, {})
    }
  }

  dynamic "storage_class_analysis" {
    for_each = length(try(flatten([each.value.storage_class_analysis]), [])) == 0 ? [] : [true]

    content {

      data_export {
        output_schema_version = try(each.value.storage_class_analysis.output_schema_version, null)

        destination {

          s3_bucket_destination {
            bucket_arn        = try(each.value.storage_class_analysis.destination_bucket_arn, aws_s3_bucket.this[0].arn)
            bucket_account_id = try(each.value.storage_class_analysis.destination_account_id, data.aws_caller_identity.current.id)
            format            = try(each.value.storage_class_analysis.export_format, "CSV")
            prefix            = try(each.value.storage_class_analysis.export_prefix, null)
          }
        }
      }
    }
  }
}
