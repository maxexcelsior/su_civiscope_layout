# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    def self.show_stats_dialog
      if @dialog_stats && @dialog_stats.visible?
        @dialog_stats.bring_to_front; return
      end
      
      w, h = self.get_stats_size
      @dialog_stats = UI::HtmlDialog.new({:dialog_title => "📊 统计中心", :width => w, :height => h, :style => UI::HtmlDialog::STYLE_DIALOG})
      self.center_dialog(@dialog_stats, w, h)
      @dialog_stats.set_file(File.join(__dir__, 'ui_stats.html'))
      
      # Ensure overlay is registered
      self.ensure_height_check_overlay(Sketchup.active_model)
      
      @dialog_stats.add_action_callback("on_tab_changed") do |_, tab_id|
        @current_active_tab = tab_id
        @is_tab_switch = true
        self.refresh_stats_ui(Sketchup.active_model.selection)
        @is_tab_switch = false
      end

      @dialog_stats.add_action_callback("convert_bldg") { self.do_convert_bldg }
      @dialog_stats.add_action_callback("apply_bldg") { |_, h, f, no, type, th| self.do_apply_bldg(h, f, no, type, th) }
      @dialog_stats.add_action_callback("convert_site") { self.do_convert_site }
      @dialog_stats.add_action_callback("apply_site") { |_, t, f, no, hl| self.do_apply_site(t, f, no, hl) }
      @dialog_stats.add_action_callback("toggle_height_check") { |_, id| self.do_toggle_height_check(id) }
      @dialog_stats.add_action_callback("set_all_height_checks") { |_, status| self.do_set_all_height_checks(status) }
      @dialog_stats.add_action_callback("start_picker") { |_, mode| Sketchup.active_model.select_tool(FunctionPickerTool.new(mode)) }
      @dialog_stats.add_action_callback("show_picker_settings") { |_, type| self.show_picker_settings_dialog(type) }
      @dialog_stats.add_action_callback("export_data") { |_, mode| UI.messagebox((mode == 'bldg' ? "建筑" : "用地") + "导出表单功能开发中...") }
      @dialog_stats.add_action_callback("faces_to_sites") { self.do_faces_to_sites }
      @dialog_stats.add_action_callback("activate_greenery_tool") { self.do_activate_greenery_tool }
      @dialog_stats.add_action_callback("ready") { self.refresh_stats_ui(Sketchup.active_model.selection) }
      @dialog_stats.add_action_callback("on_resized") { |_, w, h| self.save_stats_size(w.to_i, h.to_i) }
      @dialog_stats.set_on_closed { @dialog_stats = nil }
      @dialog_stats.show
      
      # 使用 ObserverManager 注册观察者
      model = Sketchup.active_model
      ObserverManager.register_all_observers(model)
    end

    def self.refresh_stats_ui(sel)
      return unless @dialog_stats
      begin
        targets = self.get_active_targets(sel)
        
        if targets.empty?
          @dialog_stats.execute_script("showEmptyState()")
          return
        end

        if @nested_bp_warning
          @dialog_stats.execute_script("showBanner('warning', '检测到嵌套的 BP 组。建议一个 BP 组下仅保留一个地块和若干建筑以确保计算准确性。')")
        else
          @dialog_stats.execute_script("hideBanner()")
        end

        bldg_targets = targets.select { |t| t.get_attribute("dynamic_attributes", "bldg_func") }
        site_targets = targets.select { |t| t.get_attribute("dynamic_attributes", "site_func") }
        normal_targets = targets - bldg_targets - site_targets

        if bldg_targets.any?
          render_targets('bldg', bldg_targets, sel)
        elsif site_targets.any?
          render_targets('site', site_targets, sel)
        else
          if @is_tab_switch
            active_type = @current_active_tab == 'tab-site' ? 'site' : 'bldg'
            @dialog_stats.execute_script("refreshUI('#{active_type}', 'normal', [], [], {})")
          else
            first_normal = normal_targets.first
            if first_normal && first_normal.respond_to?(:manifold?) && first_normal.manifold?
              @dialog_stats.execute_script("refreshUI('bldg', 'normal', [], [], {})")
            else
              @dialog_stats.execute_script("refreshUI('site', 'normal', [], [], {})")
            end
          end
        end
      rescue => e
        puts "[Civiscope Error] UI Refresh Failed: #{e.message}"
      end
    end

    def self.render_targets(type, valid_targets, sel)
      all_funcs = self.get_all_funcs(type)
      
      if valid_targets.length == 1
        t = valid_targets.first
        self.attach_observers(t)
        sel_array = sel.to_a
        mode = sel_array.include?(t) ? 'bim' : 'bp_group'
        data = { id: self.get_short_id(t), no: t.get_attribute("dynamic_attributes", "#{type}_no") || "" }

        if type == 'bldg'
          data.merge!({
            h: t.get_attribute("dynamic_attributes", "floor_height"),
            f: t.get_attribute("dynamic_attributes", "bldg_func"),
            th: t.get_attribute("dynamic_attributes", "total_height"),
            fc: t.get_attribute("dynamic_attributes", "floor_count"),
            ba: t.get_attribute("dynamic_attributes", "base_area"),
            area: t.get_attribute("dynamic_attributes", "bldg_area"),
            type: t.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
          })
          @dialog_stats.execute_script("refreshUI('bldg', '#{mode}', [], #{all_funcs.to_json}, #{data.to_json})")
        else
          bldg_ents = self.find_buildings_on_site(t)
          t_gfa, t_footprint, t_green = self.calculate_site_metrics(t, bldg_ents)
          
          site_area = t.get_attribute("dynamic_attributes", "site_area").to_f
          site_area = site_area > 0 ? site_area : 0.001
          
          has_global_hl = @overlay && !@overlay.sites_data.empty?
          data.merge!({
            t: t.get_attribute("dynamic_attributes", "site_type"),
            f: t.get_attribute("dynamic_attributes", "site_func"),
            area: t.get_attribute("dynamic_attributes", "site_area"),
            hl: t.get_attribute("dynamic_attributes", "height_limit") || "0",
            bldgs: self.format_bldg_data(bldg_ents),
            gfa: t_gfa,
            far: (t_gfa / site_area).round(2),
            density: ((t_footprint / site_area) * 100).round(1),
            green_m2: t_green.round(2),
            green_rate: ((t_green / site_area) * 100).round(1),
            is_checking: (@overlay && @overlay.sites_data.key?(self.get_short_id(t))),
            global_hl_on: has_global_hl
          })
          @dialog_stats.execute_script("refreshUI('site', '#{mode}', #{SITE_TYPES.to_json}, #{all_funcs.to_json}, #{data.to_json})")
        end
      else
        # Multi-select mode
        list_data = []
        total_area = 0.0
        valid_targets.each do |t|
          self.attach_observers(t)
          area_val = t.get_attribute("dynamic_attributes", "#{type}_area").to_f
          total_area += area_val
          item = { 
            id: self.get_short_id(t), 
            no: t.get_attribute("dynamic_attributes", "#{type}_no") || "",
            f: t.get_attribute("dynamic_attributes", "#{type}_func"), 
            t: t.get_attribute("dynamic_attributes", "site_type") || "", 
            area: area_val.round(2) 
          }
          if type == 'site'
            bldg_ents = self.find_buildings_on_site(t)
            t_gfa, t_footprint, t_green = self.calculate_site_metrics(t, bldg_ents)
            site_area = area_val > 0 ? area_val : 0.001
            item[:gfa] = t_gfa
            item[:far] = (t_gfa / site_area).round(2)
            item[:density] = ((t_footprint / site_area) * 100).round(1)
            item[:green_rate] = ((t_green / site_area) * 100).round(1)
          end
          list_data << item
        end
        has_global_hl = @overlay && !@overlay.sites_data.empty?
        @dialog_stats.execute_script("refreshUI('#{type}', 'multi', [], [], { list: #{list_data.to_json}, totalArea: #{total_area}, global_hl_on: #{has_global_hl} })")
      end
    end

  end
end
