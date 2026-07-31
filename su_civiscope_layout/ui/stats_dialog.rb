# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    def self.show_stats_dialog
      if @dialog_stats && @dialog_stats.visible?
        @dialog_stats.bring_to_front; return
      end
      
      w, h = self.get_stats_size
      @dialog_stats = UI::HtmlDialog.new({:dialog_title => "📊 统计中心", :width => w, :height => h, :style => UI::HtmlDialog::STYLE_DIALOG})
      pos_x, pos_y = self.get_stats_pos
      if pos_x && pos_y
        @dialog_stats.set_position(pos_x, pos_y)
      else
        self.center_dialog(@dialog_stats, w, h)
      end
      @dialog_stats.set_file(File.join(__dir__, 'ui_stats.html'))
      
      # Ensure overlays are registered
      self.ensure_height_check_overlay(Sketchup.active_model)
      self.ensure_site_number_overlay(Sketchup.active_model)
      self.ensure_bldg_number_overlay(Sketchup.active_model)
      
      @dialog_stats.add_action_callback("on_tab_changed") do |_, tab_id|
        @current_active_tab = tab_id
        @is_tab_switch = true
        self.refresh_stats_ui(Sketchup.active_model.selection)
        @is_tab_switch = false
      end

      @dialog_stats.add_action_callback("convert_bldg") { self.do_convert_bldg }
      @dialog_stats.add_action_callback("apply_bldg") { |_, h, f, no, type, th| self.do_apply_bldg(h, f, no, type, th) }
      @dialog_stats.add_action_callback("batch_set_bldg_func") do |_, func|
        model = Sketchup.active_model
        model.start_operation('批量修改建筑功能', true)
        model.selection.to_a.each do |inst|
          next unless inst.get_attribute("dynamic_attributes", "bldg_func")
          inst.set_attribute("dynamic_attributes", "bldg_func", func)
          self.auto_recalculate(inst, true, true)
        end
        self.refresh_stats_ui(model.selection)
        model.commit_operation
      end
      @dialog_stats.add_action_callback("convert_site") { self.do_convert_site }
      @dialog_stats.add_action_callback("apply_site") { |_, t, f, no, hl| self.do_apply_site(t, f, no, hl) }
      @dialog_stats.add_action_callback("refresh_roof_structure") do |_, mode, height, indent|
        model = Sketchup.active_model
        model.start_operation('刷新屋顶构筑物', true)
        model.selection.to_a.each do |inst|
          next unless inst.get_attribute("dynamic_attributes", "bldg_func")
          inst.set_attribute("dynamic_attributes", "roof_structure_mode", mode.to_s)
          if mode == 'manual'
            inst.set_attribute("dynamic_attributes", "roof_structure_manual_height", height.to_s)
            inst.set_attribute("dynamic_attributes", "roof_structure_manual_indent", indent.to_s)
          else
            # 切换回自动模式时清理手动参数，下次切回手动时重置为默认值
            inst.set_attribute("dynamic_attributes", "roof_structure_manual_height", nil)
            inst.set_attribute("dynamic_attributes", "roof_structure_manual_indent", nil)
          end
          self.auto_recalculate(inst, true, true)
        end
        self.refresh_stats_ui(model.selection)
        model.commit_operation
      end
      @dialog_stats.add_action_callback("toggle_height_check") { |_, id| self.do_toggle_height_check(id) }
      @dialog_stats.add_action_callback("toggle_site_number") { |_, id| self.toggle_site_number(id) }
      @dialog_stats.add_action_callback("batch_toggle_site_number") { |_, ids_json| self.batch_toggle_site_number(ids_json) }
      @dialog_stats.add_action_callback("toggle_bldg_number") { |_, id| self.toggle_bldg_number(id) }
      @dialog_stats.add_action_callback("set_density_mode") { |_, mode| self.save_density_mode(mode); self.refresh_stats_ui(Sketchup.active_model.selection) }
      @dialog_stats.add_action_callback("set_all_height_checks") { |_, status| self.do_set_all_height_checks(status) }
      @dialog_stats.add_action_callback("start_picker") { |_, mode| Sketchup.active_model.select_tool(FunctionPickerTool.new(mode)) }
      @dialog_stats.add_action_callback("show_picker_settings") { |_, type| self.show_picker_settings_dialog(type) }
      @dialog_stats.add_action_callback("export_data") { |_, mode| UI.messagebox((mode == 'bldg' ? "建筑" : "用地") + "导出表单功能开发中...") }
      @dialog_stats.add_action_callback("faces_to_sites") { self.do_faces_to_sites }
      @dialog_stats.add_action_callback("activate_greenery_tool") { self.do_activate_greenery_tool }
      @dialog_stats.add_action_callback("activate_base_tool") { self.do_activate_base_tool }
      @dialog_stats.add_action_callback("ready") { self.refresh_stats_ui(Sketchup.active_model.selection) }
      @dialog_stats.add_action_callback("on_resized") { |_, w, h| self.save_stats_size(w.to_i, h.to_i); self.refresh_settings_ui }
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
          bldg_type = t.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
          own_th = t.get_attribute("dynamic_attributes", "total_height").to_f
          h_effective = self.compute_effective_h(t, bldg_type, own_th)
          area_val = t.get_attribute("dynamic_attributes", "bldg_area").to_f
          reduction_enabled = self.get_reduction_settings['enabled']
          factor = self.compute_reduction_factor(bldg_type, h_effective)
          reduced_area = (area_val * factor).round(2)
          data.merge!({
            h: t.get_attribute("dynamic_attributes", "floor_height"),
            f: t.get_attribute("dynamic_attributes", "bldg_func"),
            th: t.get_attribute("dynamic_attributes", "total_height"),
            he: h_effective.round(2).to_s,
            fc: t.get_attribute("dynamic_attributes", "floor_count"),
            ba: t.get_attribute("dynamic_attributes", "base_area"),
            area: t.get_attribute("dynamic_attributes", "bldg_area"),
            type: bldg_type,
            rf: self.compute_block_refuge_floors(t, own_th, h_effective).to_s,
            rsh: t.get_attribute("dynamic_attributes", "roof_structure_height") || "0",
            rs_mode: t.get_attribute("dynamic_attributes", "roof_structure_mode") || "auto",
            rs_manual_height: t.get_attribute("dynamic_attributes", "roof_structure_manual_height") || t.get_attribute("dynamic_attributes", "roof_structure_height") || "10",
            rs_manual_indent: t.get_attribute("dynamic_attributes", "roof_structure_manual_indent") || "10",
            reduced_area: reduction_enabled ? reduced_area.to_s : nil,
            reduction_enabled: reduction_enabled,
            is_showing_number: self.bldg_number_visible?(self.get_short_id(t))
          })
          # Compute displayed indent for auto mode
          rsh_val = t.get_attribute("dynamic_attributes", "roof_structure_height").to_f
          rs_mode_val = t.get_attribute("dynamic_attributes", "roof_structure_mode") || "auto"
          bldg_func_val = t.get_attribute("dynamic_attributes", "bldg_func") || ""
          if (bldg_type == "塔楼" || bldg_type == "独立") && rsh_val > 0
            display_indent = rs_mode_val == 'manual' ?
              t.get_attribute("dynamic_attributes", "roof_structure_manual_indent").to_f :
              (bldg_func_val == '居住' ? 3.0 : 10.0)
          else
            display_indent = 0.0
          end
          data[:rsi] = display_indent.to_s
          @dialog_stats.execute_script("refreshUI('bldg', '#{mode}', [], #{all_funcs.to_json}, #{data.to_json})")
        else
          bldg_ents = self.find_buildings_on_site(t)
          t_gfa, t_footprint, t_green = self.calculate_site_metrics(t, bldg_ents)

          # 自动模式密度：仅统计紧贴地块地面的建筑标准层面积之和
          auto_base_area = self.compute_auto_base_area(t, bldg_ents)

          # 预计算每栋建筑的有效高度（缓存避免重复调用 find_buildings_under_entity）
          height_cache = {}
          bldg_ents.each { |b| height_cache[self.get_short_id(b)] = self.get_height_for_reduction(b) }

          site_area = t.get_attribute("dynamic_attributes", "site_area").to_f
          site_area = site_area > 0 ? site_area : 0.001

          # 折减后 GFA
          reduction_enabled = self.get_reduction_settings['enabled']
          t_reduced_gfa = 0.0
          t_above_reduced_gfa = 0.0
          t_below_reduced_gfa = 0.0
          above_gfa = 0.0
          below_gfa = 0.0
          bldg_ents.each do |b|
            b_area = b.get_attribute("dynamic_attributes", "bldg_area").to_f
            b_type = b.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
            h_for_r = height_cache[self.get_short_id(b)]
            factor = self.compute_reduction_factor(b_type, h_for_r)
            reduced = (b_area * factor).round(2)
            t_reduced_gfa += reduced

            if b_type == '地下空间'
              below_gfa += b_area
              t_below_reduced_gfa += reduced
            else
              above_gfa += b_area
              t_above_reduced_gfa += reduced
            end
          end
          t_reduced_gfa = t_reduced_gfa.round(2)

          # 获取地块内所有建筑的实际功能列表（用于筛选）
          bldg_funcs = bldg_ents.map { |b| b.get_attribute("dynamic_attributes", "bldg_func") }.uniq.compact

          has_global_hl = @overlay && !@overlay.sites_data.empty?
          site_id = self.get_short_id(t)
          data.merge!({
            t: t.get_attribute("dynamic_attributes", "site_type"),
            f: t.get_attribute("dynamic_attributes", "site_func"),
            area: t.get_attribute("dynamic_attributes", "site_area"),
            hl: t.get_attribute("dynamic_attributes", "height_limit") || "0",
            bldgs: self.format_bldg_data(bldg_ents, height_cache),
            bldg_funcs: bldg_funcs,  # 传递建筑功能列表
            gfa: t_gfa,
            far: (t_gfa / site_area).round(2),
            density_manual: ((t_footprint / site_area) * 100).round(1),
            density_auto: ((auto_base_area / site_area) * 100).round(1),
            density_mode: self.get_density_mode,
            max_bldg_height: bldg_ents.map { |b| self.get_height_for_reduction(b) }.max || 0,
            green_m2: t_green.round(2),
            green_rate: ((t_green / site_area) * 100).round(1),
            is_checking: (@overlay && @overlay.sites_data.key?(site_id)),
            is_showing_number: self.site_number_visible?(site_id),
            global_hl_on: has_global_hl,
            reduced_gfa: reduction_enabled ? t_reduced_gfa : nil,
            reduced_far: reduction_enabled ? (t_reduced_gfa / site_area).round(2) : nil,
            reduction_enabled: reduction_enabled,
            above_gfa: above_gfa.round(2),
            below_gfa: below_gfa.round(2),
            above_reduced_gfa: reduction_enabled ? t_above_reduced_gfa.round(2) : nil,
            below_reduced_gfa: reduction_enabled ? t_below_reduced_gfa.round(2) : nil
          })
          @dialog_stats.execute_script("refreshUI('site', '#{mode}', #{SITE_TYPES.to_json}, #{all_funcs.to_json}, #{data.to_json})")
        end
      else
        # Multi-select mode
        list_data = []
        total_area = 0.0
        total_gfa = 0.0
        total_reduced_gfa = 0.0
        total_above_reduced_gfa = 0.0
        total_below_reduced_gfa = 0.0
        reduction_enabled = self.get_reduction_settings['enabled']
        reduced_total_area = 0.0
        valid_targets.each do |t|
          self.attach_observers(t)
          area_val = t.get_attribute("dynamic_attributes", "#{type}_area").to_f
          total_area += area_val
          reduced_area_val = nil
          if type == 'bldg'
            b_type = t.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
            h_for_r = self.get_height_for_reduction(t)
            factor = self.compute_reduction_factor(b_type, h_for_r)
            reduced_area_val = (area_val * factor).round(2)
            reduced_total_area += reduced_area_val
          end
          item = {
            id: self.get_short_id(t),
            no: t.get_attribute("dynamic_attributes", "#{type}_no") || "",
            f: t.get_attribute("dynamic_attributes", "#{type}_func"),
            t: t.get_attribute("dynamic_attributes", "site_type") || "",
            area: area_val.round(2),
            reduced_area: reduced_area_val
          }
          if type == 'site'
            bldg_ents = self.find_buildings_on_site(t)
            t_gfa, t_footprint, t_green = self.calculate_site_metrics(t, bldg_ents)
            site_area = area_val > 0 ? area_val : 0.001
            item[:gfa] = t_gfa
            item[:far] = (t_gfa / site_area).round(2)
            item[:density_manual] = ((t_footprint / site_area) * 100).round(1)
            item[:density_auto] = ((self.compute_auto_base_area(t, bldg_ents) / site_area) * 100).round(1)
            item[:green_rate] = ((t_green / site_area) * 100).round(1)
            item[:is_showing_number] = self.site_number_visible?(self.get_short_id(t))
            total_gfa += t_gfa
            if reduction_enabled
              t_reduced_gfa = 0.0
              t_above_reduced = 0.0
              t_below_reduced = 0.0
              bldg_ents.each do |b|
                b_area = b.get_attribute("dynamic_attributes", "bldg_area").to_f
                b_type = b.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
                h_for_r = self.get_height_for_reduction(b)
                factor = self.compute_reduction_factor(b_type, h_for_r)
                reduced = (b_area * factor).round(2)
                t_reduced_gfa += reduced
                if b_type == '地下空间'
                  t_below_reduced += reduced
                else
                  t_above_reduced += reduced
                end
              end
              total_reduced_gfa += t_reduced_gfa
              total_above_reduced_gfa += t_above_reduced
              total_below_reduced_gfa += t_below_reduced
              item[:reduced_gfa] = t_reduced_gfa.round(2)
            end
          end
          list_data << item
        end
        has_global_hl = @overlay && !@overlay.sites_data.empty?
        multi_reduction_enabled = reduction_enabled
        multi_data = {
          list: list_data,
          totalArea: total_area,
          totalGfa: type == 'site' ? total_gfa.round(2) : nil,
          totalReducedGfa: (type == 'site' && multi_reduction_enabled) ? total_reduced_gfa.round(2) : nil,
          totalAboveReducedGfa: (type == 'site' && multi_reduction_enabled) ? total_above_reduced_gfa.round(2) : nil,
          totalBelowReducedGfa: (type == 'site' && multi_reduction_enabled) ? total_below_reduced_gfa.round(2) : nil,
          reducedTotalArea: multi_reduction_enabled ? reduced_total_area : nil,
          reduction_enabled: multi_reduction_enabled,
          global_hl_on: has_global_hl
        }
        multi_data[:funcs] = all_funcs if type == 'bldg'
        multi_data[:density_mode] = self.get_density_mode if type == 'site'
        @dialog_stats.execute_script("refreshUI('#{type}', 'multi', [], [], #{multi_data.to_json})")
      end
    end

  end
end
