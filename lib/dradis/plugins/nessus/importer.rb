module Dradis::Plugins::Nessus
  class Importer < Dradis::Plugins::Upload::Importer

    # The framework will call this function if the user selects this plugin from
    # the dropdown list and uploads a file.
    # @returns true if the operation was successful, false otherwise
    def import(params={})
      file_content    = File.read( params[:file] )

      logger.info{'Parsing nessus output file...'}
      doc = Nokogiri::XML( file_content )
      logger.info{'Done.'}

      if doc.xpath('/NessusClientData_v2/Report').empty?
        error = "No reports were detected in the uploaded file (/NessusClientData_v2/Report). Ensure you uploaded a Nessus XML v2 (.nessus) report."
        logger.fatal{ error }
        content_service.create_note text: error
        return false
      end

      doc.xpath('/NessusClientData_v2/Report').each do |xml_report|
        report_label = xml_report.attributes['name'].value
        logger.info{ "Processing report: #{report_label}" }
        # No need to create a report node for each report. It may be good to
        # create a plugin.output/nessus.reports with info for each scan, but
        # for the time being we just append stuff to the Host
        # report_node = parent.children.find_or_create_by_label(report_label)

        xml_report.xpath('./ReportHost').each do |xml_host|
          process_report_host(xml_host)
        end #/ReportHost
        logger.info{ "Report processed." }
      end  #/Report

      return true
    end # /import


    private

    # Process each /NessusClientData_v2/Report/ReportHost
    def process_report_host(xml_host)

      # 1. Create host node
      host_label = xml_host.attributes['name'].value
      host_label += " (#{xml_host.attributes['fqdn'].value})" if xml_host.attributes['fqdn']

      host_node = content_service.create_node(label: host_label, type: :host)
      logger.info{ "\tHost: #{host_label}" }

      # 2. Add host info note and host properties
      host_note_text = template_service.process_template(template: 'report_host', data: xml_host)
      content_service.create_note(text: host_note_text, node: host_node)

      if host_node.respond_to?(:properties)
        nh = ::Nessus::Host.new(xml_host)
        host_node.set_property(:fqdn,         nh.fqdn)             if nh.try(:fqdn)
        host_node.set_property(:ip,           nh.ip)               if nh.try(:ip)
        host_node.set_property(:mac_address,  nh.mac_address)      if nh.try(:mac_address)
        host_node.set_property(:netbios_name, nh.netbios_name)     if nh.try(:netbios_name)
        host_node.set_property(:os,           nh.operating_system) if nh.try(:operating_system)
        host_node.save
      end


      # 3. Add Issue and associated Evidence for this host/port combination
      xml_host.xpath('./ReportItem').each do |xml_report_item|
        next if xml_report_item.attributes['pluginID'].value == "0"
        process_report_item(xml_host, host_node, xml_report_item)
      end #/ReportItem
    end

    # Process each /NessusClientData_v2/Report/ReportHost/ReportItem
    def process_report_item(xml_host, host_node, xml_report_item)
      # 3.1. Add Issue to the project
      plugin_id = xml_report_item.attributes['pluginID'].value
      logger.info{ "\t\t\t => Creating new issue (plugin_id: #{plugin_id})" }

      issue_text = template_service.process_template(template: 'report_item', data: xml_report_item)
      issue_text << "\n\n#[Host]#\n#{xml_host.attributes['name']}\n\n"

      issue = content_service.create_issue(text: issue_text, id: plugin_id)

      # 3.2. Add Evidence to link the port/protocol and Issue
      port_info = xml_report_item.attributes['protocol'].value
      port_info += "/"
      port_info += xml_report_item.attributes['port'].value

      logger.info{ "\t\t\t => Adding reference to this host" }
      evidence_content = template_service.process_template(template: 'evidence', data: xml_report_item)

      content_service.create_evidence(issue: issue, node: host_node, content: evidence_content)

      # 3.3. Compliance check information
    end
  end
end