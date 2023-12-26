# frozen_string_literal: true

module Submissions
  module GenerateAuditTrail
    FONT_SIZE = 9
    TEXT_COLOR = '525252'
    FONT_PATH = '/fonts/LiberationSans-Regular.ttf'
    FONT_BOLD_PATH = '/fonts/LiberationSans-Bold.ttf'
    FONT_NAME = if File.exist?(FONT_PATH)
                  FONT_PATH
                else
                  'Helvetica'
                end
    FONT_BOLD_NAME = if File.exist?(FONT_BOLD_PATH)
                       FONT_BOLD_PATH
                     else
                       'Helvetica'
                     end

    INFO_CREATOR = "#{Docuseal.product_name} (#{Docuseal::PRODUCT_URL})".freeze
    SIGN_REASON = 'Signed with Sasana E Signature'
    VERIFIED_TEXT = 'Verified'
    UNVERIFIED_TEXT = 'Unverified'

    CURRENCY_SYMBOLS = {
      'USD' => '$',
      'EUR' => '€',
      'GBP' => '£'
    }.freeze

    module_function

    # rubocop:disable Metrics
    def call(submission)
      account = submission.template.account
      pkcs = Accounts.load_signing_pkcs(account)
      tsa_url = Accounts.load_timeserver_url(account)
      verify_url = Rails.application.routes.url_helpers.settings_esign_url(**Docuseal.default_url_options)

      composer = HexaPDF::Composer.new(skip_page_creation: true)
      composer.document.fonts.add(FONT_BOLD_NAME, variant: :bold)

      divider = HexaPDF::Layout::Box.create(
        margin: [0, 0, 15, 0],
        border: {
          width: [1, 0, 0, 0],
          color: %w[hp-gray-light]
        },
        height: 1
      )

      composer.page_style(:default, page_size: :A4) do |canvas, style|
        box = canvas.context.box(:media)
        canvas.save_graphics_state do
          canvas.fill_color('FAF7F5')
                .rectangle(0, 0, box.width, 20)
                .rectangle(0, box.height - 20, box.width, 20)
                .fill
        end
        style.frame = style.create_frame(canvas.context, 50)
      end

      composer.style(:base, font: FONT_NAME, font_size: FONT_SIZE, fill_color: TEXT_COLOR, line_spacing: 1.2)
      composer.style(:link, fill_color: 'hp-blue-light', underline: true)

      composer.new_page

      composer.column(columns: 1) do |column|
        add_logo(column, submission)

        column.text('Audit Log',
                    font_size: 16,
                    padding: [15, 0, 0, 0],
                    position: :float, position_hint: :right)
      end

      composer.column(columns: 1) do |column|
        column.text("Envelope ID: #{submission.id}", font_size: 12, padding: [20, 0, 10, 0], position: :float)

        unless submission.source_embed?
          column.formatted_text([{ link: verify_url, text: 'Verify', style: :link }],
                                font_size: 9, padding: [22, 0, 10, 0], position: :float, align: :right)
        end
      end

      composer.draw_box(divider)

      last_submitter = submission.submitters.where.not(completed_at: nil).order(:completed_at).last

      documents_data = Submitters.select_attachments_for_download(last_submitter).map do |document|
        original_documents = submission.template.documents.select { |e| e.uuid == document.uuid }.presence
        original_documents ||= submission.template.documents.select do |e|
          e.image? && submission.template_schema.any? do |item|
            item['attachment_uuid'] == e.uuid
          end
        end

        link =
          Rails.application.routes.url_helpers.rails_blob_url(document, **Docuseal.default_url_options)

        [
          composer.document.layout.formatted_text_box(
            [{ text: document.filename.to_s, link: }]
          ),
          composer.document.layout.formatted_text_box(
            [
              { text: "Original SHA256:\n", font: [FONT_BOLD_NAME, { variant: :bold }] },
              original_documents.map { |d| d.metadata['sha256'] || d.checksum }.join("\n"),
              "\n",
              { text: "Result SHA256:\n", font: [FONT_BOLD_NAME, { variant: :bold }] },
              document.metadata['sha256'] || document.checksum,
              "\n",
              { text: 'Generated at: ', font: [FONT_BOLD_NAME, { variant: :bold }] },
              "#{I18n.l(document.created_at.in_time_zone(account.timezone), format: :long, locale: account.locale)} " \
              "#{TimeUtils.timezone_abbr(account.timezone, document.created_at)}"
            ], line_spacing: 1.8
          )
        ]
      end

      if documents_data.present?
        composer.table(documents_data, cell_style: { padding: [0, 0, 25, 0], border: { width: 0 } })

        composer.draw_box(divider)
      end

      submission.template_submitters.filter_map do |item|
        submitter = submission.submitters.find { |e| e.uuid == item['uuid'] }

        next if submitter.blank?

        completed_event =
          submission.submission_events.find { |e| e.submitter_id == submitter.id && e.complete_form? } ||
          SubmissionEvent.new

        click_email_event =
          submission.submission_events.find { |e| e.submitter_id == submitter.id && e.click_email? }
        is_phone_verified =
          submission.template_fields.any? do |e|
            e['type'] == 'phone' && e['submitter_uuid'] == submitter.uuid && submitter.values[e['uuid']].present?
          end

        submitter_field_counters = Hash.new { 0 }

        info_rows = [
          [
            composer.document.layout.formatted_text_box(
              [
                submission.template_submitters.size > 1 && { text: "#{item['name']}\n" },
                submitter.email && { text: "#{submitter.email}\n", font: [FONT_BOLD_NAME, { variant: :bold }] },
                submitter.name && { text: "#{submitter.name}\n" },
                submitter.phone && { text: "#{submitter.phone}\n" }
              ].compact_blank, line_spacing: 1.8, padding: [0, 20, 0, 0]
            )
          ],
          [
            composer.document.layout.formatted_text_box(
              [
                submitter.email && click_email_event && {
                  text: "Email verification: #{VERIFIED_TEXT}\n"
                },
                submitter.phone && is_phone_verified && {
                  text: "Phone verification: #{VERIFIED_TEXT}\n"
                },
                completed_event.data['ip'] && { text: "IP: #{completed_event.data['ip']}\n" },
                completed_event.data['sid'] && { text: "Session ID: #{completed_event.data['sid']}\n" },
                completed_event.data['ua'] && { text: "User agent: #{completed_event.data['ua']}\n" },
                "\n"
              ].compact_blank, line_spacing: 1.8, padding: [10, 20, 20, 0]
            )
          ]
        ]

        composer.table(info_rows, cell_style: { padding: [0, 0, 0, 0], border: { width: 0 } })

        submission.template_fields.filter_map do |field|
          next if field['submitter_uuid'] != submitter.uuid

          submitter_field_counters[field['type']] += 1

          value = submitter.values[field['uuid']]

          next if Array.wrap(value).compact_blank.blank?

          [
            composer.formatted_text_box(
              [
                {
                  text: field['name'].to_s.upcase.presence ||
                        "#{field['type']} Field #{submitter_field_counters[field['type']]}\n".upcase,
                  font_size: 6
                }
              ].compact_blank, line_spacing: 1.8, padding: [0, 0, 5, 0]
            ),
            if field['type'].in?(%w[image signature initials])
              attachment = submitter.attachments.find { |a| a.uuid == value }
              image = Vips::Image.new_from_buffer(attachment.download, '').autorot

              scale = [600.0 / image.width, 600.0 / image.height].min

              resized_image = image.resize([scale, 1].min)
              io = StringIO.new(resized_image.write_to_buffer('.png'))

              width = field['type'] == 'initials' ? 100 : 200
              height = resized_image.height * (width.to_f / resized_image.width)

              composer.image(io, width:, height:, margin: [0, 0, 10, 0])
              composer.formatted_text_box([{ text: '' }])
            elsif field['type'].in?(%w[file payment])
              if field['type'] == 'payment'
                unit = CURRENCY_SYMBOLS[field['preferences']['currency']]

                price = ApplicationController.helpers.number_to_currency(field['preferences']['price'], unit:)

                composer.formatted_text_box([{ text: "Paid #{price}\n" }], padding: [0, 0, 10, 0])
              end

              composer.formatted_text_box(
                Array.wrap(value).map do |uuid|
                  attachment = submitter.attachments.find { |a| a.uuid == uuid }
                  link =
                    Rails.application.routes.url_helpers.rails_blob_url(attachment, **Docuseal.default_url_options)

                  { link:, text: "#{attachment.filename}\n", style: :link }
                end,
                padding: [0, 0, 10, 0]
              )
            elsif field['type'] == 'checkbox'
              composer.formatted_text_box([{ text: value.to_s.titleize }], padding: [0, 0, 10, 0])
            else
              if field['type'] == 'date'
                value = TimeUtils.format_date_string(value, field.dig('preferences', 'format'), account.locale)
              end

              value = value.join(', ') if value.is_a?(Array)

              composer.formatted_text_box([{ text: value.to_s.presence || 'n/a' }], padding: [0, 0, 10, 0])
            end
          ]
        end

        composer.draw_box(divider)
      end

      composer.text('Event Log', font_size: 12, padding: [10, 0, 20, 0])

      events_data = submission.submission_events.sort_by(&:event_timestamp).map do |event|
        submitter = submission.submitters.find { |e| e.id == event.submitter_id }
        [
          "#{I18n.l(event.event_timestamp.in_time_zone(account.timezone), format: :long, locale: account.locale)} " \
          "#{TimeUtils.timezone_abbr(account.timezone, event.event_timestamp)}",
          composer.document.layout.formatted_text_box(
            [
              { text: SubmissionEvents::EVENT_NAMES[event.event_type.to_sym],
                font: [FONT_BOLD_NAME, { variant: :bold }] },
              event.event_type.include?('send_') ? ' to ' : ' by ',
              if event.event_type.include?('sms') || event.event_type.include?('phone')
                submitter.phone
              else
                (submitter.name || submitter.email || submitter.phone)
              end
            ]
          )
        ]
      end

      composer.table(events_data, cell_style: { padding: [0, 0, 20, 0], border: { width: 0 } }) if events_data.present?

      io = StringIO.new

      composer.document.trailer.info[:Creator] = INFO_CREATOR

      sign_params = {
        reason: SIGN_REASON,
        certificate: pkcs.certificate,
        key: pkcs.key,
        certificate_chain: pkcs.ca_certs || []
      }

      sign_params[:timestamp_handler] = Submissions::TimestampHandler.new(tsa_url:) if tsa_url

      composer.document.sign(io, **sign_params)

      ActiveStorage::Attachment.create!(
        blob: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(io.string), filename: "Audit Log - #{submission.template.name}.pdf"
        ),
        name: 'audit_trail',
        record: submission
      )
    end

    def add_logo(column, _submission = nil)
      column.image(PdfIcons.logo_io, width: 40, height: 40, position: :float)

      column.formatted_text([{ text: 'DocuSeal',
                               link: Docuseal::PRODUCT_URL }],
                            font_size: 20,
                            font: [FONT_BOLD_NAME, { variant: :bold }],
                            width: 100,
                            padding: [12, 0, 0, 8],
                            position: :float, position_hint: :left)
    end
    # rubocop:enable Metrics
  end
end
