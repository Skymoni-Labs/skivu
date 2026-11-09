    function SkillsTab(props) {
      const [data,setData]=React.useState(null),[error,setError]=React.useState('');
      const [query,setQuery]=React.useState(''),[blockedOnly,setBlockedOnly]=React.useState(false);
      const [active,setActive]=React.useState(''),[detail,setDetail]=React.useState(null);
      const load=()=>api({op:'skillCatalog'}).then(r=>{
        if(!r||r.ok===false)throw Error(r&&r.error||'技能目录读取失败');
        setData(r);setError('');
      }).catch(e=>setError(e.message||String(e)));
      React.useEffect(()=>{load();},[props.refreshKey]);
      const open=skill=>{
        setActive(skill.name);setDetail(null);setError('');
        if(skill.availability!=='available'){setError(skill.blockedReason||'此技能正文未包含');return;}
        api({op:'skillRead',name:skill.name}).then(r=>{
          if(!r||r.ok===false)throw Error(r&&r.error||'技能读取失败');
          setDetail(r);
        }).catch(e=>setError(e.message||String(e)));
      };
      const items=data&&data.items||[],summary=data&&data.availability&&data.availability.summary;
      const needle=query.trim().toLowerCase();
      const visible=items.filter(s=>(!blockedOnly||s.availability!=='available')&&(!needle||(s.name+' '+s.description+' '+s.whenToUse).toLowerCase().includes(needle)));
      return h('div',{className:'skivu-skills'},
        h('div',{className:'skivu-skills-head'},h('strong',null,'小云技能资料'),h('button',{className:'rt-btn',onClick:load},'刷新')),
        h('p',null,data&&data.note||'正在读取技能目录…'),
        summary?h('p',null,'共 '+items.length+' 项 · 正文可读 '+summary.available+' 项 · 未包含 '+summary.broken+' 项'):null,
        h('input',{className:'rt-input',placeholder:'过滤技能',value:query,onChange:e=>setQuery(e.target.value)}),
        h('label',{className:'skivu-skills-filter'},h('input',{type:'checkbox',checked:blockedOnly,onChange:e=>setBlockedOnly(e.target.checked)}),'只看未包含正文'),
        h('div',{className:'skivu-skills-list'},visible.map(s=>h('button',{key:s.name,className:'skivu-skill'+(active===s.name?' on':''),onClick:()=>open(s)},
          h('strong',null,s.name),h('span',null,s.availability==='available'?'正文可读':'系统防护隔离'),h('small',null,s.description))),visible.length===0?h('p',null,'没有匹配的技能'):null),
        error?h('div',{className:'rt-err',role:'alert'},error):null,
        h('div',{className:'skivu-skill-detail'},detail?h('div',null,h('h4',null,detail.name),h('p',null,detail.whenToUse||''),h('pre',{className:'rt-md'},detail.content)):h('p',null,active?'请选择其他技能查看正文。':'选择上方技能查看正文。')));
    }
